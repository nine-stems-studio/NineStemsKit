import Foundation
import Observation
import StoreKit

/// App-specific non-consumable and optional annual subscription identifiers.
public struct PurchaseConfiguration: Sendable {
    /// Non-consumable lifetime unlock identifier.
    public let lifetimeProductID: String
    /// Optional auto-renewable, one-year subscription identifier.
    public let annualProductID: String?
    /// Creates a configuration without any kit-owned product IDs.
    public init(lifetimeProductID: String, annualProductID: String? = nil) {
        self.lifetimeProductID = lifetimeProductID; self.annualProductID = annualProductID
    }
    var ids: Set<String> { Set([lifetimeProductID, annualProductID].compactMap { $0 }) }
}

/// A verified product's kind, restricted to the two supported purchase models.
public enum PurchaseKind: String, Codable, Sendable {
    /// A non-consumable unlock.
    case lifetime
    /// An auto-renewable yearly subscription.
    case annual
}

/// Display information obtained from StoreKit, not a manually maintained price table.
public struct PurchaseProduct: Identifiable, Equatable, Sendable {
    /// Product identifier supplied by the app.
    public let id: String
    /// Storefront-localised product name.
    public let name: String
    /// Storefront-localised price.
    public let displayPrice: String
    /// Supported purchase model.
    public let kind: PurchaseKind
}

/// An entitlement originally obtained from a verified StoreKit transaction.
public struct PurchaseEntitlement: Codable, Equatable, Sendable {
    /// Product identifier.
    public let productID: String
    /// StoreKit transaction identifier.
    public let transactionID: UInt64
    /// Lifetime or annual purchase model.
    public let kind: PurchaseKind
    /// End of subscription access, including a verified billing grace period when supplied by StoreKit.
    public let expirationDate: Date?
    /// Refund or revocation date, if any.
    public let revocationDate: Date?
    func active(at date: Date) -> Bool {
        revocationDate == nil && (kind == .lifetime || (expirationDate.map { $0 > date } ?? false))
    }
}

/// Current user-facing purchase operation. Access is tracked independently of transient operations.
public enum PurchaseActivity: Equatable, Sendable {
    /// No operation is in progress.
    case idle
    /// Loading the catalogue.
    case loading
    /// Waiting for a purchase result for a product.
    case purchasing(String)
    /// Synchronising purchases after an explicit restore request.
    case restoring
    /// The system is awaiting approval; no access is granted by this state.
    case pending
    /// An operation failed with a displayable description.
    case failed(String)
}

enum PurchaseOutcome: Sendable { case verified(PurchaseEntitlement), pending, cancelled }
enum PurchaseUpdate: Sendable { case verified(PurchaseEntitlement), failed(String) }
enum PurchaseFailure: LocalizedError {
    case unavailable, unverified, wrongKind
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This product is not available. Please try again.", bundle: .module)
        case .unverified: String(localized: "The purchase could not be verified. Please restore purchases or try again.", bundle: .module)
        case .wrongKind: String(localized: "The configured product must be a lifetime unlock or an annual subscription.", bundle: .module)
        }
    }
}

@MainActor protocol PurchaseClient: AnyObject {
    func products() async throws -> [PurchaseProduct]
    func purchase(_ id: String) async throws -> PurchaseOutcome
    func current() async throws -> [PurchaseEntitlement]
    func sync() async throws
    func finish(_ id: UInt64) async
    func updates() -> AsyncStream<PurchaseUpdate>
}

@MainActor final class StoreKitClient: PurchaseClient {
    let configuration: PurchaseConfiguration
    var catalogue: [String: Product] = [:]
    var unfinished: [UInt64: StoreKit.Transaction] = [:]
    private let gracePeriodExpiration: (String, String) async throws -> Date?
    init(_ configuration: PurchaseConfiguration,
         gracePeriodExpiration: @escaping (String, String) async throws -> Date? = StoreKitClient.gracePeriodExpiration) {
        self.configuration = configuration
        self.gracePeriodExpiration = gracePeriodExpiration
    }

    private static func gracePeriodExpiration(group: String, productID: String) async throws -> Date? {
        let statuses = try await Product.SubscriptionInfo.status(for: group)
        return statuses.compactMap { status in
            guard status.state == .inGracePeriod,
                  case .verified(let renewal) = status.renewalInfo,
                  case .verified(let transaction) = status.transaction,
                  transaction.productID == productID else { return nil }
            return renewal.gracePeriodExpirationDate
        }.max()
    }

    func kind(_ transaction: StoreKit.Transaction) throws -> PurchaseKind {
        if transaction.productID == configuration.lifetimeProductID, transaction.productType == .nonConsumable { return .lifetime }
        if transaction.productID == configuration.annualProductID, transaction.productType == .autoRenewable { return .annual }
        throw PurchaseFailure.wrongKind
    }
    func entitlement(_ transaction: StoreKit.Transaction) throws -> PurchaseEntitlement {
        let kind = try kind(transaction)
        return PurchaseEntitlement(productID: transaction.productID, transactionID: transaction.id, kind: kind,
                                   expirationDate: transaction.expirationDate, revocationDate: transaction.revocationDate)
    }
    func includingGracePeriod(_ entitlement: PurchaseEntitlement, group: String?) async -> PurchaseEntitlement {
        guard entitlement.kind == .annual, entitlement.revocationDate == nil, let group else { return entitlement }
        // Status is optional enrichment. A lookup failure must not discard a verified transaction.
        guard let grace = try? await gracePeriodExpiration(group, entitlement.productID) else { return entitlement }
        return PurchaseEntitlement(productID: entitlement.productID, transactionID: entitlement.transactionID, kind: entitlement.kind,
                                   expirationDate: max(entitlement.expirationDate ?? grace, grace), revocationDate: entitlement.revocationDate)
    }
    func products() async throws -> [PurchaseProduct] {
        let products = try await Product.products(for: configuration.ids)
        var result: [PurchaseProduct] = []
        for product in products {
            let kind: PurchaseKind
            if product.id == configuration.lifetimeProductID, product.type == .nonConsumable { kind = .lifetime }
            else if product.id == configuration.annualProductID, product.type == .autoRenewable,
                    product.subscription?.subscriptionPeriod.unit == .year,
                    product.subscription?.subscriptionPeriod.value == 1 { kind = .annual }
            else { throw PurchaseFailure.wrongKind }
            catalogue[product.id] = product
            result.append(PurchaseProduct(id: product.id, name: product.displayName, displayPrice: product.displayPrice, kind: kind))
        }
        return result.sorted { $0.id < $1.id }
    }
    func purchase(_ id: String) async throws -> PurchaseOutcome {
        guard let product = catalogue[id] else { throw PurchaseFailure.unavailable }
        switch try await product.purchase() {
        case .success(.verified(let transaction)):
            unfinished[transaction.id] = transaction
            return .verified(try entitlement(transaction))
        case .success(.unverified): throw PurchaseFailure.unverified
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PurchaseFailure.unavailable
        }
    }
    func current() async throws -> [PurchaseEntitlement] {
        var result: [PurchaseEntitlement] = []
        for await value in StoreKit.Transaction.currentEntitlements {
            // Isolate invalid entries so one transaction cannot discard other verified purchases.
            guard case .verified(let transaction) = value,
                  configuration.ids.contains(transaction.productID),
                  let entitlement = try? entitlement(transaction) else { continue }
            result.append(await includingGracePeriod(entitlement, group: transaction.subscriptionGroupID))
        }
        return result
    }
    func sync() async throws { try await AppStore.sync() }
    func finish(_ id: UInt64) async {
        await unfinished[id]?.finish(); unfinished[id] = nil
    }
    func updates() -> AsyncStream<PurchaseUpdate> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await value in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    switch value {
                    case .verified(let transaction) where self.configuration.ids.contains(transaction.productID):
                        do {
                            self.unfinished[transaction.id] = transaction
                            continuation.yield(.verified(try self.entitlement(transaction)))
                        } catch { continuation.yield(.failed(error.localizedDescription)) }
                    case .unverified(let transaction, _) where self.configuration.ids.contains(transaction.productID):
                        continuation.yield(.failed(PurchaseFailure.unverified.localizedDescription))
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Main-actor purchase controller. Own for the app's lifetime and call start at launch.
/// Cache is a device-local convenience, not server-side receipt validation; StoreKit remains authoritative.
@MainActor @Observable
public final class PurchaseStore {
    /// Current catalogue; prices come directly from StoreKit.
    public private(set) var products: [PurchaseProduct] = []
    /// Entitlements accepted from StoreKit or restored from the namespaced local cache.
    public private(set) var entitlements: [PurchaseEntitlement] = []
    /// Current operation or last error.
    public private(set) var activity: PurchaseActivity = .idle
    /// True while entitlement information comes only from the namespaced device cache.
    public private(set) var isUsingCachedEntitlements = true
    /// Whether an unexpired, non-revoked entitlement is present now.
    public var hasAccess: Bool { entitlements.contains { $0.active(at: Date()) } }
    /// Whether a product load, purchase or restore is currently running.
    public private(set) var isBusy = false
    private let configuration: PurchaseConfiguration
    private let client: any PurchaseClient
    private let defaults: UserDefaults
    private let cacheKey: String
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    private var started = false
    private var revision = 0

    /// Creates a controller using StoreKit 2 and app-scoped preferences.
    public convenience init(configuration: PurchaseConfiguration, defaults: UserDefaults = .standard) {
        self.init(configuration: configuration, defaults: defaults, client: StoreKitClient(configuration))
    }
    init(configuration: PurchaseConfiguration, defaults: UserDefaults, client: any PurchaseClient) {
        self.configuration = configuration; self.defaults = defaults; self.client = client
        cacheKey = "NineStemsKit.purchases." + configuration.ids.sorted().joined(separator: "|")
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode([PurchaseEntitlement].self, from: data) {
            entitlements = cached.filter {
                (($0.productID == configuration.lifetimeProductID && $0.kind == .lifetime)
                 || ($0.productID == configuration.annualProductID && $0.kind == .annual)) && $0.active(at: Date())
            }
        }
        let stream = client.updates()
        listener = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled, let self else { break }
                switch update {
                case .verified(let entitlement):
                    self.accept(entitlement)
                    await client.finish(entitlement.transactionID)
                    // Reconcile older refunds/renewals against the complete, current StoreKit view.
                    await self.refreshEntitlements(preserving: entitlement.productID)
                case .failed(let message): self.activity = .failed(message)
                }
            }
        }
        scheduleExpiry()
    }
    deinit { listener?.cancel(); expiryTask?.cancel() }

    /// Loads products and refreshes locally available StoreKit entitlements once. Safe to call from multiple views.
    public func start() async {
        guard !started else { return }; started = true
        await loadProducts()
        await refreshEntitlements()
    }
    /// Retries catalogue loading. Entitlements are unaffected by catalogue errors.
    public func loadProducts() async {
        guard !isBusy else { return }; isBusy = true; activity = .loading
        defer { isBusy = false }
        do {
            products = try await client.products()
            activity = products.isEmpty ? .failed(PurchaseFailure.unavailable.localizedDescription) : .idle
        } catch { activity = .failed(error.localizedDescription) }
    }
    /// Replaces the cache with StoreKit's current entitlements, including an authoritative empty result.
    /// A failed refresh retains the prior cache and reports the error; individual unverified entries are omitted.
    public func refreshEntitlements() async {
        await refreshEntitlements(preserving: nil)
    }
    private func refreshEntitlements(preserving productID: String?) async {
        revision += 1; let request = revision
        let justVerified = entitlements.filter { $0.productID == productID }
        do {
            let values = try await client.current()
            guard request == revision else { return }
            // currentEntitlements can lag a purchase/update. Keep the accepted transaction when absent,
            // while allowing an enumerated refund or renewal for that product to take precedence.
            let merged = values + justVerified.filter { accepted in !values.contains { $0.productID == accepted.productID } }
            entitlements = merged.filter { valid($0) && $0.active(at: Date()) }
            isUsingCachedEntitlements = false; persist(); scheduleExpiry()
        } catch { if request == revision { activity = .failed(error.localizedDescription) } }
    }
    /// Purchases a loaded product. Cancellation returns to idle; pending approval does not grant access.
    public func purchase(productID: String) async {
        guard !isBusy else { return }
        guard products.contains(where: { $0.id == productID }) else { activity = .failed(PurchaseFailure.unavailable.localizedDescription); return }
        isBusy = true; activity = .purchasing(productID)
        defer { isBusy = false }
        do {
            switch try await client.purchase(productID) {
            case .verified(let entitlement):
                guard valid(entitlement) else { throw PurchaseFailure.wrongKind }
                accept(entitlement); await client.finish(entitlement.transactionID)
                await refreshEntitlements(preserving: entitlement.productID)
            case .pending: activity = .pending
            case .cancelled: activity = .idle
            }
        } catch { activity = .failed(error.localizedDescription) }
    }
    /// Requests App Store synchronisation only in response to the user's restore action.
    public func restore() async {
        guard !isBusy else { return }; isBusy = true; activity = .restoring
        defer { isBusy = false }
        do { try await client.sync(); activity = .idle; await refreshEntitlements() }
        catch { activity = .failed(error.localizedDescription) }
    }
    private func valid(_ value: PurchaseEntitlement) -> Bool {
        (value.productID == configuration.lifetimeProductID && value.kind == .lifetime)
            || (value.productID == configuration.annualProductID && value.kind == .annual)
    }
    private func accept(_ value: PurchaseEntitlement) {
        guard valid(value) else { return }
        revision += 1
        entitlements.removeAll { $0.productID == value.productID }
        if value.active(at: Date()) { entitlements.append(value) }
        activity = .idle; isUsingCachedEntitlements = false; persist(); scheduleExpiry()
    }
    private func persist() { if let data = try? JSONEncoder().encode(entitlements) { defaults.set(data, forKey: cacheKey) } }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = entitlements.compactMap(\.expirationDate).min() else { return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.entitlements.removeAll { !$0.active(at: Date()) }
            self.persist(); self.scheduleExpiry()
        }
    }
}
