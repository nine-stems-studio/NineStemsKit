import SwiftUI
import NSDesign

/// App-authored paywall copy and optional links; prices are formatted from the StoreKit catalogue by the app.
public struct PaywallCopy: Sendable {
    /// Main value proposition.
    public let title: String
    /// Benefits and access explanation.
    public let message: String
    /// Restore button label.
    public let restoreTitle: String
    /// Optional privacy policy link.
    public let privacyURL: URL?
    /// Optional terms link, required by the shipping app when offering a subscription.
    public let termsURL: URL?
    /// Creates copy owned and localised by the app.
    public init(title: String, message: String, restoreTitle: String = "Restore purchases", privacyURL: URL? = nil, termsURL: URL? = nil) {
        self.title = title; self.message = message; self.restoreTitle = restoreTitle
        self.privacyURL = privacyURL; self.termsURL = termsURL
    }
}

/// A configurable paywall. The app formats each purchase button using a StoreKit product's displayPrice.
public struct PaywallView: View {
    private let store: PurchaseStore
    private let copy: PaywallCopy
    private let purchaseLabel: (PurchaseProduct) -> String
    /// Creates a paywall with app-provided copy and storefront-aware price labels.
    public init(store: PurchaseStore, copy: PaywallCopy, purchaseLabel: @escaping (PurchaseProduct) -> String) {
        self.store = store; self.copy = copy; self.purchaseLabel = purchaseLabel
    }
    /// Catalogue, purchase status and restore controls.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.large) {
                Text(copy.title).font(.largeTitle.bold())
                Text(copy.message)
                if store.hasAccess { Label(String(localized: "Access unlocked", bundle: .module), systemImage: "checkmark.seal.fill").foregroundStyle(DesignTokens.accent) }
                ForEach(store.products) { product in
                    Button { Task { await store.purchase(productID: product.id) } } label: {
                        Text(purchaseLabel(product)).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(DesignTokens.accent)
                        .disabled(store.isBusy).accessibilityIdentifier("purchase.\(product.kind.rawValue)")
                }
                if store.isBusy { ProgressView().accessibilityLabel(Text("Purchase operation in progress", bundle: .module)) }
                if store.activity == .pending { Text("Awaiting purchase approval.", bundle: .module).font(.callout) }
                if case .failed(let message) = store.activity {
                    Text(message).foregroundStyle(DesignTokens.warning)
                    Button(String(localized: "Retry loading products", bundle: .module)) { Task { await store.loadProducts() } }.disabled(store.isBusy)
                }
                Button(copy.restoreTitle) { Task { await store.restore() } }.disabled(store.isBusy)
                    .accessibilityIdentifier("purchase.restore")
                HStack {
                    if let url = copy.privacyURL { Link(String(localized: "Privacy", bundle: .module), destination: url) }
                    if let url = copy.termsURL { Link(String(localized: "Terms", bundle: .module), destination: url) }
                }.font(.footnote)
            }.padding(DesignTokens.large)
        }.task { await store.start() }
    }
}
