# Friction log — swiftui-chat archetype

Agent: Grok Build (DX walkthrough subagent)
Date: 2026-07-25
ManifoldKit version: v0.73.0-29-gd023b1a6 (commit d023b1a6)

---

## Entry 1
- **Trying to**: Find the canonical path for multi-session SwiftUI + Ollama from docs alone
- **Expected**: One clear happy-path doc that ends in a working chat with sessions
- **Actual**: Had to stitch `docs/QUICKSTART.md` (Hello World + Ollama seed) with `docs/SWIFTUI-MULTI-SESSION.md` (sidebar + `sessionManager` + restore). QUICKSTART Hello World is single-session and leaves model unloaded; multi-session doc says quickStart dispatches load for cloud endpoints but Ollama seed still needs post-quickStart insert + `loadSelectedEndpoint()` on first launch. Docs are good but not one page.
- **Resolution**: Followed multi-session §2 + QUICKSTART "Seeding an Ollama endpoint"
- **Category**: DOC-MISSING (single consolidated recipe for the common case exists partially in multi-session §6 as manual bootstrap, but not for quickStart+Ollama+sidebar)
- **Severity**: minor

## Entry 2
- **Trying to**: Compile multi-session root using the documented `.environment(\.endpointStore, kit.bootstrap.endpointStore)` injection from SWIFTUI-MULTI-SESSION.md §6 / AGENTS.md bootstrap recipe
- **Expected**: Compiles with `import ManifoldKit` only (umbrella re-exports UI + Runtime + Persistence)
- **Actual**: Compile error: `value of type 'EnvironmentValues' has no member 'endpointStore'` and KeyPath is not WritableKeyPath for `SwiftDataEndpointStore`. The environment key is not visible through the umbrella alone.
- **Resolution**: Dropped the injection. We pre-seed Ollama in code and do not mount `APIConfigurationView`, so the key is unnecessary. Would need `ManifoldUIModelManagement` (or wherever the key lives) if using that sheet — docs do not say the key requires that product when showing the multi-session recipe with only `import ManifoldKit`.
- **Category**: DOC-WRONG
- **Severity**: major

## Entry 3
- **Trying to**: Launch the pure SwiftPM `executableTarget` SwiftUI `@main` App and see a window
- **Expected**: `swift run DXSwiftUIChat` (or running the debug binary) opens a normal macOS chat window
- **Actual**: Process can stay alive but without an `.app` bundle / `Info.plist` / `NSPrincipalClass`, window discovery and activation are flaky from automation; packaging a minimal `DXSwiftUIChat.app` (Info.plist + MacOS binary + ad-hoc codesign) made the window reliable and screenshotable. Docs show `@main struct …: App` snippets but do not mention the consumer packaging step for SwiftPM-only hosts (Xcode app targets hide this).
- **Resolution**: Wrapped binary in a minimal `.app` bundle under `app/DXSwiftUIChat.app`
- **Category**: DOC-MISSING
- **Severity**: minor

## Entry 4
- **Trying to**: Run the drop-in `ChatView` without microphone capability
- **Expected**: Quiet degradation (docs say mic hides when `NSMicrophoneUsageDescription` is absent)
- **Actual**: UI correctly hid/disabled mic, but surfaces a yellow composer banner: "Voice input is enabled but unavailable — add NSMicrophoneUsageDescription to Info.plist." For a text-only chat evaluation this is noisy. Docs also document `ManifoldConfiguration.shared.features = .init(showAudioInput: false, …)` to remove the control — I did not set that in the happy-path multi-session snippet, and neither does the multi-session guide.
- **Resolution**: Logged; banner is honest but opt-out is not in the multi-session happy path
- **Category**: API-ERGONOMICS
- **Severity**: papercut

## Entry 5
- **Trying to**: Use only `import ManifoldKit` for the Ollama seed snippet that docs sometimes show with `import ManifoldInference`
- **Expected**: Either works via umbrella re-exports, or docs consistently use one import set
- **Actual**: `APIEndpointRecord`, `BackendName`-adjacent types, and `loadSelectedEndpoint()` all compiled with umbrella-only. Good. Minor doc inconsistency (QUICKSTART Ollama seed also `import ManifoldInference`).
- **Resolution**: Umbrella alone is enough
- **Category**: DOC-WRONG (inconsistency only)
- **Severity**: papercut

## Entry 6
- **Trying to**: Understand whether first-launch Ollama after `quickStart()` is automatic
- **Expected**: Multi-session §2 claim that `quickStart` dispatches load for first configured cloud endpoint
- **Actual**: That is true only when the endpoint is **already in the store before/during** `quickStart`. Seeding *after* return still requires the explicit `setAvailableEndpoints` + `selectedEndpoint` + `await loadSelectedEndpoint()` triad (documented in QUICKSTART, easy to miss when starting from multi-session §2 alone). First-run path is more ceremony than "one call".
- **Resolution**: Followed QUICKSTART Ollama seed exactly; first `loadSelectedEndpoint()` returned `isModelLoaded=true` promptly
- **Category**: API-ERGONOMICS
- **Severity**: minor

