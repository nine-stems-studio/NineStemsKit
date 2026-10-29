import SwiftUI
import NSDesign

/// One app-authored onboarding page, including its free-use allowance.
public struct OnboardingPage: Identifiable, Sendable {
    /// Stable page identifier.
    public let id: String
    /// A one-sentence value proposition.
    public let title: String
    /// Explanatory copy.
    public let message: String
    /// Free allowance or other access information.
    public let allowance: String
    /// An SF Symbol name.
    public let systemImage: String
    /// Creates a page without imposing an app-specific workflow.
    public init(id: String, title: String, message: String, allowance: String, systemImage: String) {
        self.id = id; self.title = title; self.message = message
        self.allowance = allowance; self.systemImage = systemImage
    }
}

/// A configurable sequence; the app persists completion in its own preferences.
public struct OnboardingView: View {
    private let pages: [OnboardingPage]
    private let nextTitle: String
    private let finishTitle: String
    private let onComplete: () -> Void
    @State private var index = 0
    /// Creates an onboarding sequence. An empty sequence presents the completion button.
    public init(pages: [OnboardingPage], nextTitle: String = "Continue", finishTitle: String = "Get started",
                onComplete: @escaping () -> Void) {
        self.pages = pages; self.nextTitle = nextTitle; self.finishTitle = finishTitle; self.onComplete = onComplete
    }
    /// The current page and accessible progress controls.
    public var body: some View {
        VStack(spacing: DesignTokens.large) {
            if pages.indices.contains(index) {
                let page = pages[index]
                ScrollView {
                    VStack(spacing: DesignTokens.large) {
                        Image(systemName: page.systemImage).font(.system(size: 56)).foregroundStyle(DesignTokens.accent)
                            .accessibilityHidden(true)
                        Text(page.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(page.message).multilineTextAlignment(.center)
                        ListCard { Text(page.allowance).font(.callout) }
                    }.padding(.vertical, DesignTokens.large)
                }
                Text("\(index + 1) / \(pages.count)").font(.footnote).foregroundStyle(.secondary)
            }
            Button(index + 1 < pages.count ? nextTitle : finishTitle) {
                if index + 1 < pages.count { index += 1 } else { onComplete() }
            }.buttonStyle(.borderedProminent).tint(DesignTokens.accent).accessibilityIdentifier("onboarding.continue")
        }.padding(DesignTokens.large)
    }
}
