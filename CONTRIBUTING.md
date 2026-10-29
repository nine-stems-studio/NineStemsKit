# Contributing to NineStemsKit

Thank you for helping maintain this package. It is small on purpose: shared building blocks that several apps depend on. Please keep these rules so that no app breaks when the package moves.

## Rules for every pull request

1. **Public API is additive only.** Do not change or remove existing `public` types, method signatures or default behaviour. If a change is unavoidable, open an issue first and describe the migration.
2. **No app-specific logic.** No product IDs, prices, business rules, brand copy or regional legal text. Apps inject those; the package ships none of them.
3. **Tests come with the change.** `swift test` must pass. New capabilities need cases under `Tests/`; PDF layout changes need a sample under `Validation/`.
4. **No new dependencies**, no change to the minimum platforms (iOS 17, macOS 14), no bundled images or fonts.
5. **English only** in code, comments, documentation and commit messages. Never commit keys, accounts or internal information.
6. **Flow:** branch from `main` → open a pull request that says why, what changed and how it was tested → wait for CI and one maintainer approval → a maintainer merges. No direct pushes to `main`, no force pushes, no tags (releases are cut by the Nine Stems maintainers).
7. **Bugs:** open an issue with a minimal reproduction and your Xcode / OS versions before sending a fix.

## Building and testing

Build and test on a Mac with Xcode 26 or later from the package root:

```sh
swift build
swift test
```

The package depends on SwiftUI, StoreKit, SwiftData and other Apple frameworks, so it does not build on Linux.

## Design principle

Apps own their models, product IDs, prices, navigation and copy. Before adding a switch or a branch for one app's need, ask whether every app would want it. If not, it belongs in the app.
