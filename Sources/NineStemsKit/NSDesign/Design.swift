import SwiftUI

/// Shared visual values; apps own their navigation and screen composition.
public enum DesignTokens {
    /// Adaptive primary accent.
    public static let accent = Color(red: 0.08, green: 0.40, blue: 0.34)
    /// Background for small reusable surfaces.
    public static let surface = Color.primary.opacity(0.045)
    /// A warning colour accompanied by text in StatusBadge.
    public static let warning = Color(red: 0.72, green: 0.12, blue: 0.16)
    /// Small spacing in points.
    public static let small: CGFloat = 8
    /// Standard spacing in points.
    public static let medium: CGFloat = 16
    /// Large spacing in points.
    public static let large: CGFloat = 24
    /// Shared card corner radius in points.
    public static let radius: CGFloat = 16
    /// Dynamic Type headline style.
    public static let heading: Font = .title2.weight(.semibold)
    /// Dynamic Type reading style.
    public static let body: Font = .body
    /// Dynamic Type supporting style.
    public static let caption: Font = .footnote
}

/// A surface for an app-provided list item or small group of controls.
public struct ListCard<Content: View>: View {
    private let content: Content
    /// Creates a card from app-owned content.
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    /// The accessible card content.
    public var body: some View {
        content.padding(DesignTokens.medium).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
    }
}

/// An empty list message with an app-supplied symbol, title and explanation.
public struct EmptyState: View {
    private let title: String
    private let message: String
    private let symbol: String
    /// Creates an empty-state message; symbol names refer to system SF Symbols.
    public init(title: String, message: String, systemImage: String = "tray") {
        self.title = title; self.message = message; symbol = systemImage
    }
    /// The accessible message.
    public var body: some View {
        VStack(spacing: DesignTokens.medium) {
            Image(systemName: symbol).font(.largeTitle).accessibilityHidden(true)
            Text(title).font(DesignTokens.heading)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(DesignTokens.large).frame(maxWidth: .infinity)
    }
}

/// A red warning badge that communicates its meaning without relying on colour.
public struct StatusBadge: View {
    private let text: String
    /// Creates a badge with an app-supplied warning label.
    public init(_ text: String) { self.text = text }
    /// The badge's text and warning symbol.
    public var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(DesignTokens.caption).foregroundStyle(DesignTokens.warning)
            .padding(DesignTokens.small).background(DesignTokens.warning.opacity(0.08), in: Capsule())
    }
}
