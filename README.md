# NineStemsKit

A small, dependency-free Swift package of shared SwiftUI building blocks for iOS apps: design tokens, onboarding, StoreKit 2 purchases, PDF rendering, local storage, export and compliance copy.

## Modules

Import `NineStemsKit` to get all seven modules, or depend on an individual library product.

| Module | What it provides |
| --- | --- |
| `NSDesign` | Adaptive colours, Dynamic Type fonts, spacing and small reusable SwiftUI components. |
| `NSOnboarding` | Onboarding flow driven by any number of `OnboardingPage` values; the app stores completion. |
| `NSPurchase` | StoreKit 2 `PurchaseStore` for non-consumable and optional subscription products; the app injects its own product IDs. Restore is an explicit user action. |
| `NSPDF` | `PDFDocumentTemplate` rendering of app-owned blocks (text, tables, local images, page breaks) to A4 or Letter. No URLs are fetched. |
| `NSStore` | SwiftData container setup for app-owned models with optional migration plan, plus JSON backups via app-owned Codable DTOs. |
| `NSExport` | `ExportDocument` for SwiftUI `fileExporter`, sharing local URLs, or presenting an unsent system mail composer. |
| `NSCompliance` | Display of app-supplied disclaimer text with a dated HTTPS citation; links open only after user action. |

Apps own their models, product IDs, business rules, navigation, text, prices and export destinations.

## Installation (Swift Package Manager)

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nine-stems-studio/NineStemsKit.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["NineStemsKit"])
]
```

Or in Xcode: File > Add Package Dependencies, then enter the repository URL.

```swift
import NineStemsKit
```

## Requirements

- Swift tools 6.0 (Swift 6 language mode)
- iOS 17 or later
- macOS 14 or later (used for host-side tests)
- No third-party dependencies

## Running the tests

```sh
swift test
```

Or run `bash Scripts/verify.sh`, which builds and tests with a local module cache. Tests use Apple frameworks (SwiftUI, StoreKit, SwiftData, UIKit/CoreGraphics) and are expected to run on macOS.

## License

MIT. See [LICENSE](LICENSE).

## Scope and support

- Built for Nine Stems Studio's own apps; shared under the MIT License so that other projects can use it.
- Issues and pull requests are welcome. There is no support commitment or response-time promise.
- Apps own their models, product IDs, prices and copy; this package ships none of them.
