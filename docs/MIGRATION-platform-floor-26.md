# Migration: iOS and macOS 26 floor

**Audience:** consumer
**Status:** current

The next ManifoldKit minor raises the package and example-app deployment targets
from iOS 18 / macOS 15 to **iOS 26 / macOS 26**. This follows the project's n-1
platform policy now that iOS and macOS 27 are current.

## Update your app target

Set the target that links ManifoldKit to iOS 26 and macOS 26. A SwiftPM
manifest can keep `swift-tools-version: 6.1` by spelling the versions as
strings:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "ManifoldKit", package: "ManifoldKit")
            ]
        )
    ]
)
```

The app source can continue to import the umbrella at that floor:

```swift
import ManifoldKit

print(BackendName.foundation.rawValue)
```

Xcode projects should set `IPHONEOS_DEPLOYMENT_TARGET` and
`MACOSX_DEPLOYMENT_TARGET` to `26.0`. Supporting an older operating system now
requires pinning to the prior ManifoldKit minor.

The floor does not make every newer API unconditional: ManifoldKit keeps its
availability guards for APIs introduced in macOS/iOS 26.2 and in macOS/iOS 27.

## Remove the retired traits

Delete `SystemAIProviderExtension` and `CoreAI` from any SwiftPM `traits:`
array. Both names were no-op forward declarations: neither unlocked a target or
changed the build graph. The remaining opt-in traits are `Server` and `Macros`.

The Xcode 27 investigation found no system-provider extension point. Apple's
`FoundationModels.LanguageModelExecutor` remains a possible future integration,
but it requires a real target and a separate decision about tool-loop ownership;
it is not enabled by a trait. See
[WWDC 2026 Trait-Stubs Disposition](wwdc-2026-trait-stubs.md) for the evidence.
