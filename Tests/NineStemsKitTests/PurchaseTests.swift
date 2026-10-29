import XCTest
@testable import NSPurchase

@MainActor private final class FakePurchases: PurchaseClient {
    var catalogue = [PurchaseProduct(id: "sample.lifetime", name: "Lifetime", displayPrice: "£9.99", kind: .lifetime),
                     PurchaseProduct(id: "sample.annual", name: "Annual", displayPrice: "£4.99", kind: .annual)]
    var outcome: PurchaseOutcome = .cancelled
    var currentValues: [PurchaseEntitlement] = []
    var resolveCurrent: (() async -> [PurchaseEntitlement])?
    var currentCalls = 0
    var failCurrent = false
    var failSync = false
    var finished: [UInt64] = []
    var continuation: AsyncStream<PurchaseUpdate>.Continuation?
    var currentWaiter: CheckedContinuation<[PurchaseEntitlement], any Error>?
    var suspendCurrent = false
    func products() async throws -> [PurchaseProduct] { catalogue }
    func purchase(_ id: String) async throws -> PurchaseOutcome { outcome }
    func current() async throws -> [PurchaseEntitlement] {
        currentCalls += 1
        if suspendCurrent {
            suspendCurrent = false
            return try await withCheckedThrowingContinuation { currentWaiter = $0 }
        }
        if failCurrent { throw PurchaseFailure.unverified }
        if let resolveCurrent { return await resolveCurrent() }
        return currentValues
    }
    func sync() async throws { if failSync { throw PurchaseFailure.unavailable } }
    func finish(_ id: UInt64) async { finished.append(id) }
    func updates() -> AsyncStream<PurchaseUpdate> { AsyncStream { continuation = $0 } }
}

final class PurchaseTests: XCTestCase {
    @MainActor private func environment() -> (PurchaseStore, FakePurchases, UserDefaults) {
        let defaults = UserDefaults(suiteName: "NSKitTests.\(UUID().uuidString)")!
        let fake = FakePurchases()
        return (PurchaseStore(configuration: PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual"),
                              defaults: defaults, client: fake), fake, defaults)
    }
    private func entitlement(_ id: String = "sample.lifetime", kind: PurchaseKind = .lifetime,
                             expiration: Date? = nil, revoked: Date? = nil) -> PurchaseEntitlement {
        PurchaseEntitlement(productID: id, transactionID: 42, kind: kind, expirationDate: expiration, revocationDate: revoked)
    }

    @MainActor func testVerifiedPurchasePersistsBeforeFinishAndRestoresOffline() async {
        let (store, fake, defaults) = environment()
        await store.start()
        fake.outcome = .verified(entitlement())
        await store.purchase(productID: "sample.lifetime")
        XCTAssertTrue(store.hasAccess); XCTAssertEqual(fake.finished, [42]); XCTAssertEqual(store.activity, .idle)
        let offlineClient = FakePurchases(); offlineClient.failCurrent = true
        let offline = PurchaseStore(configuration: PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual"),
                                    defaults: defaults, client: offlineClient)
        XCTAssertTrue(offline.hasAccess); XCTAssertTrue(offline.isUsingCachedEntitlements)
        await offline.start()
        XCTAssertTrue(offline.hasAccess)
        if case .failed = offline.activity {} else { XCTFail("Unverified refresh must surface an error") }
    }
    @MainActor func testPendingAndCancellationNeverGrantAccess() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .pending; await store.purchase(productID: "sample.lifetime")
        XCTAssertEqual(store.activity, .pending); XCTAssertFalse(store.hasAccess); XCTAssertTrue(fake.finished.isEmpty)
        fake.outcome = .cancelled; await store.purchase(productID: "sample.lifetime")
        XCTAssertEqual(store.activity, .idle); XCTAssertFalse(store.hasAccess)
    }
    @MainActor func testStatusFailurePreservesAnnualAndOtherVerifiedPurchasesAfterFinish() async {
        for throughUpdate in [false, true] {
            let (store, fake, defaults) = environment(); await store.start()
            defer { fake.resolveCurrent = nil }
            let annual = entitlement("sample.annual", kind: .annual, expiration: Date().addingTimeInterval(3600))
            let lifetime = entitlement()
            var statusCalls = 0
            let client = StoreKitClient(PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual")) { _, _ in
                statusCalls += 1
                XCTAssertTrue(store.hasAccess, "Persist the verified transaction before querying optional status")
                XCTAssertEqual(fake.finished, [annual.transactionID], "Finish before querying optional status")
                let cached = try JSONDecoder().decode([PurchaseEntitlement].self, from: XCTUnwrap(defaults.data(forKey: "NineStemsKit.purchases.sample.annual|sample.lifetime")))
                XCTAssertEqual(cached, [annual])
                throw PurchaseFailure.unavailable
            }
            fake.resolveCurrent = {
                [await client.includingGracePeriod(lifetime, group: nil),
                 await client.includingGracePeriod(annual, group: "sample.group")]
            }
            if throughUpdate {
                fake.continuation?.yield(.verified(annual))
                for _ in 0..<100 where store.entitlements.count < 2 { await Task.yield() }
            } else {
                fake.outcome = .verified(annual)
                await store.purchase(productID: "sample.annual")
            }
            XCTAssertEqual(statusCalls, 1)
            XCTAssertEqual(store.entitlements, [lifetime, annual])
            XCTAssertEqual(store.activity, .idle)
        }
    }
    @MainActor func testStatusFailureDoesNotExtendExpiredOrRevokedAnnual() async {
        let client = StoreKitClient(PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual")) { _, _ in
            throw PurchaseFailure.unavailable
        }
        for annual in [entitlement("sample.annual", kind: .annual, expiration: .distantPast),
                       entitlement("sample.annual", kind: .annual, expiration: .distantFuture, revoked: Date())] {
            let value = await client.includingGracePeriod(annual, group: "sample.group")
            XCTAssertEqual(value, annual)
            XCTAssertFalse(value.active(at: Date()))
        }
    }
    @MainActor func testVerifiedGracePeriodExtendsAnnualWithoutShorteningTransactionExpiry() async {
        let grace = Date().addingTimeInterval(3600)
        let client = StoreKitClient(PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual")) { _, _ in grace }
        let expired = entitlement("sample.annual", kind: .annual, expiration: .distantPast)
        let extended = await client.includingGracePeriod(expired, group: "sample.group")
        XCTAssertEqual(extended.expirationDate, grace); XCTAssertTrue(extended.active(at: Date()))
        let future = entitlement("sample.annual", kind: .annual, expiration: .distantFuture)
        let unchanged = await client.includingGracePeriod(future, group: "sample.group")
        XCTAssertEqual(unchanged, future)
    }
    @MainActor func testLaggingEnumerationKeepsPurchaseAndApprovalInCache() async {
        for throughUpdate in [false, true] {
            let (store, fake, defaults) = environment(); await store.start()
            let purchased = entitlement()
            if throughUpdate {
                fake.continuation?.yield(.verified(purchased))
                for _ in 0..<100 where fake.currentCalls < 2 { await Task.yield() }
            } else {
                fake.outcome = .verified(purchased)
                await store.purchase(productID: purchased.productID)
            }
            XCTAssertGreaterThanOrEqual(fake.currentCalls, 2, "Exercise reconciliation with an empty enumeration")
            XCTAssertEqual(fake.finished, [purchased.transactionID])
            XCTAssertEqual(store.entitlements, [purchased])
            let offline = PurchaseStore(configuration: PurchaseConfiguration(lifetimeProductID: "sample.lifetime", annualProductID: "sample.annual"),
                                        defaults: defaults, client: FakePurchases())
            XCTAssertTrue(offline.hasAccess, "A lagging enumeration must not erase the persisted purchase")
        }
    }
    @MainActor func testRevocationUpdateRemovesCachedAccess() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .verified(entitlement()); await store.purchase(productID: "sample.lifetime")
        fake.continuation?.yield(.verified(entitlement(revoked: Date())))
        for _ in 0..<100 where store.hasAccess { await Task.yield() }
        XCTAssertFalse(store.hasAccess); XCTAssertEqual(store.entitlements, [])
    }
    @MainActor func testAuthoritativeEmptyRestoreClearsCacheAndFailedRestoreKeepsAccess() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .verified(entitlement()); await store.purchase(productID: "sample.lifetime")
        fake.failSync = true; await store.restore(); XCTAssertTrue(store.hasAccess)
        fake.failSync = false; await store.restore(); XCTAssertFalse(store.hasAccess)
        XCTAssertFalse(store.isUsingCachedEntitlements)
    }
    @MainActor func testExpiredAnnualDoesNotGrantAccessAndFutureAnnualDoes() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .verified(entitlement("sample.annual", kind: .annual, expiration: Date().addingTimeInterval(-1)))
        await store.purchase(productID: "sample.annual"); XCTAssertFalse(store.hasAccess)
        fake.outcome = .verified(entitlement("sample.annual", kind: .annual, expiration: Date().addingTimeInterval(3600)))
        await store.purchase(productID: "sample.annual"); XCTAssertTrue(store.hasAccess)
    }
    @MainActor func testUnverifiedUpdateCannotUnlock() async {
        let (store, fake, _) = environment(); await store.start()
        fake.continuation?.yield(.failed("Unverified"))
        for _ in 0..<100 { if case .failed = store.activity { break }; await Task.yield() }
        XCTAssertFalse(store.hasAccess); XCTAssertTrue(fake.finished.isEmpty)
    }
    @MainActor func testForeignProductAndWrongKindCannotUnlock() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .verified(entitlement("another.app")); await store.purchase(productID: "sample.lifetime")
        XCTAssertFalse(store.hasAccess); XCTAssertTrue(fake.finished.isEmpty)
        fake.outcome = .verified(entitlement("sample.lifetime", kind: .annual, expiration: .distantFuture))
        await store.purchase(productID: "sample.lifetime"); XCTAssertFalse(store.hasAccess)
    }
    @MainActor func testStaleRefreshCannotOverwriteNewPurchase() async {
        let (store, fake, _) = environment(); await store.start()
        fake.suspendCurrent = true
        let refresh = Task { await store.refreshEntitlements() }
        for _ in 0..<100 where fake.currentWaiter == nil { await Task.yield() }
        fake.outcome = .verified(entitlement()); await store.purchase(productID: "sample.lifetime")
        fake.currentWaiter?.resume(returning: []); await refresh.value
        XCTAssertTrue(store.hasAccess)
    }
    @MainActor func testCacheIsIsolatedByProductConfiguration() async {
        let (store, fake, defaults) = environment(); await store.start()
        fake.outcome = .verified(entitlement()); await store.purchase(productID: "sample.lifetime")
        let other = PurchaseStore(configuration: PurchaseConfiguration(lifetimeProductID: "other.lifetime"), defaults: defaults, client: FakePurchases())
        XCTAssertFalse(other.hasAccess)
    }
    @MainActor func testApprovalUpdateUnlocksAndOlderRefundReconcilesCurrentAccess() async {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .pending; await store.purchase(productID: "sample.lifetime")
        fake.currentValues = [entitlement()]
        fake.continuation?.yield(.verified(entitlement()))
        for _ in 0..<100 where !store.hasAccess { await Task.yield() }
        XCTAssertTrue(store.hasAccess)
        fake.continuation?.yield(.verified(entitlement(revoked: Date())))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(store.hasAccess, "A stale refund must not remove a newer current entitlement")
    }
    @MainActor func testAnnualExpiryRemovesEntitlementWhileControllerRemainsAlive() async throws {
        let (store, fake, _) = environment(); await store.start()
        fake.outcome = .verified(entitlement("sample.annual", kind: .annual, expiration: Date().addingTimeInterval(0.03)))
        await store.purchase(productID: "sample.annual")
        XCTAssertTrue(store.hasAccess)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(store.hasAccess); XCTAssertTrue(store.entitlements.isEmpty)
    }
}
