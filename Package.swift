// swift-tools-version: 6.0
import PackageDescription

let modules = ["NSPurchase", "NSOnboarding", "NSPDF", "NSStore", "NSDesign", "NSCompliance", "NSExport"]
let package = Package(
    name: "NineStemsKit",
    defaultLocalization: "en-GB",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NineStemsKit", targets: ["NineStemsKit"])]
        + modules.map { .library(name: $0, targets: [$0]) },
    targets: modules.map { name in
        .target(name: name, dependencies: name == "NSOnboarding" || name == "NSCompliance" || name == "NSPurchase" ? ["NSDesign"] : [],
                path: "Sources/NineStemsKit/\(name)",
                resources: name == "NSPurchase" || name == "NSStore" ? [.process("Resources")] : [])
    } + [
        .target(name: "NineStemsKit", dependencies: modules.map { .byName(name: $0) }, path: "Sources/NineStemsKit/Umbrella"),
        .testTarget(name: "NineStemsKitTests", dependencies: modules.map { .byName(name: $0) }, resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
