# Share & Action Extension Recipe (App Group handoff)

This guide explains how ManifoldDemo wires a Share Extension and an Action Extension to hand content into a new `ChatViewModel` session without linking ManifoldKit inside the extension.

## Architecture overview

```
┌─────────────────────────┐         UserDefaults (App Group)
│  Share / Action Extension│ ──────► key: "bck.pending-share"
│  (pure Foundation)       │         value: PendingSharePayload (JSON)
└─────────────────────────┘
           ↑ writes, then completeRequest()

┌─────────────────────────┐ .onChange(of: scenePhase == .active)
│  ManifoldDemo (host app) │ ──reads──► PendingSharePayload
│                          │ ──────────► PendingPayload (ManifoldUI)
│  ChatViewModel           │ ──────────► ingestPendingPayload(_:intent:)
└─────────────────────────┘
```

The key isolation boundary is `PendingSharePayload` — a pure Foundation `Codable` struct compiled into all three targets (host app, Share Extension, Action Extension). Extensions cannot link ManifoldKit (App Extensions must not import frameworks with `@main`/`App` conformances), so this thin shared type is the handoff contract.

## File map

```
Example/ManifoldDemo/Extensions/
├── PendingSharePayload.swift          # Shared Codable (no BCK deps)
├── ShareExtension/
│   ├── ShareViewController.swift      # UIViewController principal class
│   ├── ShareExtension.entitlements    # App Group entitlement
│   └── ShareExtensionInfo.plist       # NSExtension config
└── ActionExtension/
    ├── ActionViewController.swift     # UIViewController principal class
    ├── ActionExtension.entitlements   # App Group entitlement
    └── ActionExtensionInfo.plist      # NSExtension config
```

Host-app changes live in `ManifoldDemoApp.swift` (`checkForPendingSharePayload`, `pendingPayload(from:)`, `.onChange(of: scenePhase)`, `.task(id:)`).

## Entitlement checklist

All three targets — the host app and both extensions — must share the same App Group identifier in their entitlements:

```xml
<!-- *.entitlements -->
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.manifoldkit.demo</string>
</array>
```

`ManifoldDemo.entitlements` already had this from the App Intents path (#442). Each extension gets its own `.entitlements` file with the same group.

## PendingSharePayload

```swift
// Extensions/PendingSharePayload.swift — pure Foundation, no BCK deps.
// Compiled into: ManifoldDemo, ManifoldDemoShareExtension, ManifoldDemoActionExtension.
struct PendingSharePayload: Codable, Sendable {
    enum Kind: String, Codable { case text, url, image }

    var kind: Kind
    var text: String?
    var urlString: String?
    var imageData: Data?
    var imageMimeType: String?
    var source: String   // "shareExtension" | "actionExtension"
}
```

Extensions write this to the App Group and complete immediately — no inference happens inside an extension.

## Extension write pattern

```swift
// ShareViewController.swift (same pattern for ActionViewController)
private func submitAndComplete(payload: PendingSharePayload) {
    guard let data = try? JSONEncoder().encode(payload),
          let defaults = UserDefaults(suiteName: "group.com.manifoldkit.demo") else {
        extensionContext?.completeRequest(returningItems: nil)
        return
    }
    defaults.set(data, forKey: "bck.pending-share")
    defaults.synchronize()
    extensionContext?.completeRequest(returningItems: nil)
}
```

`defaults.synchronize()` flushes the write before the extension process is suspended — important because the host app may wake within milliseconds.

## Host-app drain pattern

```swift
// ManifoldDemoApp.swift

.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active {
        checkForPendingSharePayload()
    }
}
.task(id: modelContainer != nil ? 1 : 0) {
    // Handles the cold-launch race: scenePhase fires .active before
    // the SwiftData container task completes.
    guard modelContainer != nil, let staged = stagedSharePayload else { return }
    stagedSharePayload = nil
    guard let payload = pendingPayload(from: staged) else { return }
    await chatViewModel.ingestPendingPayload(payload, intent: .newSession(preset: nil))
}

private func checkForPendingSharePayload() {
    guard let defaults = UserDefaults(suiteName: DemoAppGroup.identifier),
          let data = defaults.data(forKey: DemoAppGroup.pendingShareKey),
          let sharePayload = try? JSONDecoder().decode(PendingSharePayload.self, from: data) else {
        return
    }
    // Remove before ingesting — crash-safe: won't replay on next launch.
    defaults.removeObject(forKey: DemoAppGroup.pendingShareKey)

    if modelContainer != nil {
        guard let payload = pendingPayload(from: sharePayload) else { return }
        Task { @MainActor in
            await chatViewModel.ingestPendingPayload(payload, intent: .newSession(preset: nil))
        }
    } else {
        // Container still initialising — stage for .task(id:) drain.
        stagedSharePayload = sharePayload
    }
}
```

## Cold-launch race

The two-stage pattern (`stagedSharePayload` + `.task(id:)`) handles the race where:

1. The user taps in the Share sheet → extension writes to App Group → extension completes.
2. iOS cold-launches the host app.
3. `scenePhase` fires `.active` **before** the async `ModelContainer` task finishes.
4. `checkForPendingSharePayload` reads the payload but finds `modelContainer == nil`.
5. The payload is stored in `stagedSharePayload`.
6. `modelContainer` is set → `.task(id: 1)` fires → payload is drained.

## App Group key separation

| Key | Written by | Consumed by |
|-----|-----------|-------------|
| `bck.inbound` | `AskManifoldDemoIntent` (App Intent) | `handleOpenURL` via `manifolddemo://ingest` |
| `bck.pending-share` | Share Extension / Action Extension | `checkForPendingSharePayload` on foreground |

Using separate keys prevents the two paths from clobbering each other.

## Extension point IDs

| Extension | Info.plist point ID | Platform |
|-----------|----------------------|----------|
| Share | `com.apple.share-services` | iOS (also valid on macOS via Catalyst) |
| Action | `com.apple.ui-services` | iOS only |

The extensions are iOS-only Xcode targets (`SDKROOT = iphoneos`). The host-app Embed App Extensions build phase uses `platformFilter = ios` so macOS builds are unaffected.

## Adapting this pattern for your own app

1. Add an App Group to your app's entitlements (Signing & Capabilities → App Groups).
2. Copy `PendingSharePayload.swift` into your project; adjust fields as needed.
3. Add Share / Action Extension targets and add the same App Group entitlement.
4. In each extension, write a JSON-encoded `PendingSharePayload` to the shared `UserDefaults` key and call `completeRequest`.
5. In your app's `WindowGroup`, add `.onChange(of: scenePhase)` and drain on `.active`.
6. Pass the payload to `chatViewModel.ingestPendingPayload(_:intent:)`.

For the `intent` parameter, `.newSession(preset: nil)` opens a fresh chat. Pass a `SessionPreset` if you want the session pre-configured (system prompt, model, temperature).
