# Friction log — swiftui-chat archetype

Agent: Grok (Build subagent / DX walkthrough)
Date: 2026-07-25
ManifoldKit version: v0.73.0 (checkout d023b1a6, describe v0.73.0-29-gd023b1a6)
Backend steering: Apple Foundation Models (run 2 of 3)
Host: macOS 26.5.2 arm64, Xcode 26.6 / Swift 6.3.3

---

## Entry 1
- **Trying to**: Find the canonical multi-session SwiftUI + Foundation Models bootstrap recipe.
- **Expected**: One clear "do this" path in README or QUICKSTART for macOS 26 Foundation.
- **Actual**: Three related docs (README Hello World, `docs/QUICKSTART.md`, `docs/SWIFTUI-MULTI-SESSION.md`) plus MinimalExample. Foundation-specific steps are buried under "First-launch backend selection" / "Seeding Foundation Models" rather than in the first Hello World block. MinimalExample does **not** load Foundation at all — so the "canonical sample" leaves you with "No model loaded" on macOS 26 unless you also read the deeper docs.
- **Resolution**: Combined multi-session recipe from SWIFTUI-MULTI-SESSION §2 with Foundation seeding from QUICKSTART §"Seeding Foundation Models" (`foundationModelProvider` + `loadFoundationModelIfAvailable()`).
- **Category**: DOC-MISSING | API-DISCOVERABILITY
- **Severity**: major

## Entry 2
- **Trying to**: Decide whether `quickStart()` auto-selects Foundation Models on macOS 26.
- **Expected**: Consistent answer across docs.
- **Actual**: Contradictory guidance:
  - `SWIFTUI-MULTI-SESSION.md` §2: "`quickStart()` also dispatches a load for whichever backend it selected: the built-in policy's local model (Foundation-first, then first on-disk GGUF)…"
  - `QUICKSTART.md`: "Apple Foundation Models backend is *registered* … but it is **not auto-selected by `quickStart()`**" and requires `foundationModelProvider` + `loadFoundationModelIfAvailable()`.
- **Resolution**: Followed the explicit QUICKSTART Foundation seeding path. Runtime matched QUICKSTART: without the two ChatViewModel steps, generation would not work; with them (on a clean store), `sendMessage` succeeded.
- **Category**: DOC-WRONG
- **Severity**: major

## Entry 3
- **Trying to**: Declare `platforms: [.macOS(.v26)]` in consumer `Package.swift` (brief + QUICKSTART-CLI §1 Foundation recipe).
- **Expected**: Compiles with the tools-version docs recommend for consumers (`// swift-tools-version: 6.1` per QUICKSTART.md prerequisites).
- **Actual**: Manifest fails: `'v26' is unavailable` — `MacOSVersion.v26` was introduced in PackageDescription 6.2. Must use `// swift-tools-version: 6.2`. QUICKSTART-CLI §1 is correct (uses 6.2); QUICKSTART.md / general consumer guidance still says 6.1+ and does not warn about this when targeting Foundation / macOS 26.
- **Resolution**: Bumped tools-version to 6.2.
- **Category**: DOC-WRONG
- **Severity**: major

## Entry 4
- **Trying to**: Launch the SwiftUI chat UI via a bare `swift run` / `.build/.../DXSwiftUIChat` executable (SwiftPM package, no `.app` bundle).
- **Expected**: Window appears with `NavigationSplitView` + `SessionListView` + `ChatView` as in the docs.
- **Actual**: First UI shapes (status `VStack` wrapping `NavigationSplitView`) crashed the process with `EXC_BREAKPOINT` / `+[NSApplication _crashOnException:]` during AppKit layout (`crash.ips`). Console also logged `Cannot index window tabs due to missing main bundle identifier`. After removing the wrapping `VStack` and setting `.defaultSize` / min frame, the UI stayed up and generation worked.
- **Resolution**: Match the docs' RootView shape more closely; avoid extra layout wrappers around `NavigationSplitView`. Prefer a real Xcode `.app` for production — bare SwiftPM executables are under-documented as a host shape.
- **Category**: API-ERGONOMICS | DOC-MISSING
- **Severity**: major

## Entry 5
- **Trying to**: Call `sendMessage` after `createSession()` + `switchToSession` on a relaunch (or after partial failed runs), while `isModelLoaded == true` / `modelLoadState == .loaded`.
- **Expected**: Turn completes (docs say `switchToSession` dispatches load).
- **Actual**: `ConversationError.inference(InferenceError.inferenceFailure("No model loaded"))` even though ChatViewModel reported loaded. Creating a fresh session mid-smoke consistently broke Foundation until the store was wiped and we stayed on the restored/active session. `isModelLoaded` was a false positive relative to the inference engine after session churn.
- **Resolution**: Stay on the session `quickStart` restored; re-call `foundationModelProvider` + `loadFoundationModelIfAvailable()` after bootstrap; wipe dirty store when experimenting. Did not open Sources (forced-blindness).
- **Category**: API-ERGONOMICS | API-GAP
- **Severity**: major

## Entry 6
- **Trying to**: Observe bootstrap/generation logs when launching with stdout/stderr redirected to files.
- **Expected**: `print` statements appear in the log files.
- **Actual**: Empty stdout/stderr until I switched to unbuffered `FileHandle.standardError.write`. Process exit 133 looked like a silent crash with no app logs (crash report only).
- **Resolution**: `dxLog` helper writing UTF-8 lines to stderr. Worth a one-liner in DX docs for headless/scripted hosts.
- **Category**: API-ERGONOMICS
- **Severity**: papercut

## Entry 7
- **Trying to**: Pass `backends: [FoundationBackends.self]` and `configuration:` to `quickStart`.
- **Expected**: Argument order is free or documented at the call site.
- **Actual**: Compiler: `argument 'backends' must precede argument 'configuration'`. Easy fix once seen; not shown in the multi-session guide's Foundation section.
- **Resolution**: `quickStart(backends:configuration:)`.
- **Category**: API-DISCOVERABILITY
- **Severity**: papercut

## Entry 8
- **Trying to**: Capture a window screenshot for the deliverable (`screencapture` / `screencapture -l`).
- **Expected**: Image of the chat UI with messages.
- **Actual**: Full-display captures came back pure black (TCC Screen Recording not granted to this automation host). Generation is proven via stderr logs + SQLite rows under `~/Library/Application Support/com.manifoldkit.dx.walkthrough.swiftui-chat.run2/`.
- **Resolution**: Logged proof accepted by brief ("log, or stdout proof"); `screenshot.png` may be black/unusable in this environment.
- **Category**: DOC-MISSING (no note about Screen Recording for scripted DX)
- **Severity**: papercut

## Entry 9
- **Trying to**: Use MinimalExample as the drop-in multi-session + Foundation evaluation app.
- **Expected**: Sample covers the happy path for the default on-device backend on macOS 26.
- **Actual**: MinimalExample is single-surface `ChatView` only, no `SessionListView` / `sessionManager` environment, and no Foundation `foundationModelProvider` wiring. Multi-session + Foundation is only in docs, not in the sample.
- **Resolution**: Hand-wrote app from SWIFTUI-MULTI-SESSION + QUICKSTART Foundation section.
- **Category**: DOC-MISSING
- **Severity**: minor

---

## What worked smoothly (counterbalance)

- Cold `swift build` against local path `.package(name: "ManifoldKit", path: …)` — ~47s with warm dependency caches; clean compile of consumer target.
- Umbrella `import ManifoldKit` covered `QuickStartResult`, `ChatView`, `SessionListView`, `SessionManagerViewModel`, `ManifoldBootstrap` surface, Foundation registrar types.
- Persistence just works once configured: unique `bundleIdentifier` → store under Application Support; relaunch restores session title + messages (2 → 4 → 6 messages across launches).
- Documented `sendMessage(_:)` → `ChatMessage.content` returned a real Foundation reply: `Hello from foundation smoke.`
- Multi-session recipe (`environment(viewModel)` + `environment(sessionManager)` + `modelContainer` + `onChange` → `switchToSession`) compiled and ran once layout was unwrapped.
