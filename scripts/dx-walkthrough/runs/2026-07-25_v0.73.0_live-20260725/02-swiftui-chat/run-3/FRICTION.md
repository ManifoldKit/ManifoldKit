# Friction log — swiftui-chat archetype

Agent: Grok (DX walkthrough run-3)
Date: 2026-07-25
ManifoldKit version: 0.73.0 (commit d023b1a6)

Path chosen: **manual `ManifoldBootstrap.build` + Ollama endpoint seed + multi-session UI** (not `quickStart()`), per run-3 steering.

---

## Entry 1
- **Trying to**: Follow the "full recipe" in `docs/SWIFTUI-MULTI-SESSION.md` §6 (manual bootstrap + Ollama seed + multi-session sidebar) and get a live composer on first launch.
- **Expected**: Seeding an `APIEndpointRecord` into `bootstrap.endpointStore` (as the §6 snippet does) would be enough for `ChatView` to talk to Ollama after register + session restore.
- **Actual**: §6 inserts the endpoint but never sets `chatVM.selectedEndpoint`, never calls `setAvailableEndpoints`, and never `await loadSelectedEndpoint()`. Without the separate "Seeding an Ollama endpoint" section in `docs/QUICKSTART.md`, the app boots cleanly with a sidebar and empty chat, but the model is not loaded (`isModelLoaded` stays false / composer inert). I had to stitch §6 + QUICKSTART first-launch load steps by hand.
- **Resolution**: After `insertEndpoint`, call `setAvailableEndpoints([ollama])`, assign `selectedEndpoint`, then `await loadSelectedEndpoint()`. Worked immediately once those three lines were added.
- **Category**: DOC-MISSING
- **Severity**: major

## Entry 2
- **Trying to**: On relaunch, rely on the multi-session restore path (`configureAndLoad` → `selectInitialSession` → `switchToSession`) to re-bind the previously seeded Ollama endpoint, as section 7 / quickStart docs claim for cloud endpoints.
- **Expected**: With the endpoint already in the store, `switchToSession` (or bootstrap) would select it and dispatch a load, matching the relaunch story in QUICKSTART ("no extra `loadSelectedEndpoint()` call is required").
- **Actual**: After restore, `chatVM.selectedEndpoint` was still `nil`. Without an explicit relaunch branch that re-selects the first endpoint and awaits `loadSelectedEndpoint()`, generation would not start. Session restore itself worked (same session UUID); only endpoint/model re-selection was incomplete on the manual path.
- **Resolution**: After session restore, if `selectedEndpoint == nil`, fetch endpoints, set available/selected, await load. Documented for `quickStart` relaunch, not for the manual scaffold.
- **Category**: DOC-MISSING
- **Severity**: major

## Entry 3
- **Trying to**: Find one copy-paste path for "macOS multi-session chat with Ollama" as a new consumer.
- **Expected**: Either MinimalExample or a single doc page would be enough end-to-end.
- **Actual**: MinimalExample is **only** `quickStart()` + single `ChatView` (no sidebar, no manual bootstrap). Multi-session lives in `docs/SWIFTUI-MULTI-SESSION.md`. Ollama first-load awaits live in QUICKSTART. Named loading milestones / `BootstrapLoadingView` are in DocC (`BootstrapLoadingScreen.md`). Building the manual path required three documents plus AGENTS.md Part 1. Individually each is clear; the "one full recipe" claim in §6 is slightly oversold.
- **Resolution**: Read all three; assembled working app in ~one attempt after stitching.
- **Category**: DOC-MISSING
- **Severity**: major

## Entry 4
- **Trying to**: Surface model browser / API configuration UI as shown in the full recipe.
- **Expected**: `import ManifoldKit` umbrella would include `APIConfigurationView` / `ModelManagementSheet`.
- **Actual**: Those live in product `ManifoldUIModelManagement`, which must be an explicit Package.swift dependency and a second import. This is documented correctly in SWIFTUI-MULTI-SESSION §5; still a second "why doesn't this type resolve?" moment if you only read the AGENTS.md bootstrap sketch (which does mention the product).
- **Resolution**: Added `.product(name: "ManifoldUIModelManagement", package: "ManifoldKit")` and `import ManifoldUIModelManagement`.
- **Category**: API-DISCOVERABILITY
- **Severity**: minor

## Entry 5
- **Trying to**: Use `import ManifoldKit` + `.modelContainer(bootstrap.modelContainer)` as in the multi-session snippets.
- **Expected**: One import covers SwiftData modifier type inference.
- **Actual**: Need `import SwiftData` for `.modelContainer` type-checking (MinimalExample comments this; multi-session §6 snippets omit the import). Compiler error without it.
- **Resolution**: `import SwiftData` at top of app file.
- **Category**: DOC-MISSING
- **Severity**: papercut

## Entry 6
- **Trying to**: Match the brief's "Target macOS 26" in Package.swift platforms.
- **Expected**: `.macOS(.v26)` or clear guidance that consumer packages should declare macOS 26 when targeting Foundation Models / current OS.
- **Actual**: ManifoldKit's own Package.swift floors at `.macOS(.v15)` / iOS 18. SwiftPM platform enum for tools-version 6.1 does not push consumers to 26; the toolchain still builds for the host (arm64-apple-macosx26.0). No friction at compile time — only a mismatch between brief wording and package floors.
- **Resolution**: Used `.macOS(.v15)` to match the package; ran on macOS 26 host.
- **Category**: DOC-MISSING
- **Severity**: papercut

## Entry 7
- **Trying to**: Launch the SPM executable and get a clean chat window.
- **Expected**: Window opens; no unrelated permission prompts for an Ollama-only seed path.
- **Actual**: macOS showed a Documents-folder access prompt ("DXSwiftUIChat would like to access files in your Documents folder") for a bare SwiftPM `@main` executable. Likely model-discovery / storage probing under the hood. Not documented in the SwiftUI multi-session recipe. Also, SPM GUI apps redirect stdout poorly when not a proper `.app` bundle (harness issue; worked around with file logging).
- **Resolution**: Dismissed dialog; chat still worked via Ollama. File logger for E2E proof.
- **Category**: API-ERGONOMICS
- **Severity**: minor

## Entry 8
- **Trying to**: Confirm session persistence without reading Sources/.
- **Expected**: Docs promise store under Application Support keyed by `bundleIdentifier`; relaunch restores sessions/messages.
- **Actual**: Worked exactly as documented. Store at `~/Library/Application Support/com.manifoldkit.dx.walkthrough.swiftui-chat.run3/`. Same session id after quit+relaunch; `ZCHATMESSAGE` retained prior turns; new probe turns append. `configureAndLoad` + `selectInitialSession` race guidance (#1464) was accurate and easy to follow.
- **Resolution**: N/A — positive signal.
- **Category**: API-ERGONOMICS
- **Severity**: papercut (positive: low friction)

## Entry 9
- **Trying to**: Cold-build a consumer package against local ManifoldKit path with explicit `name:`.
- **Expected**: 5–10 minute cold compile of transitive deps.
- **Actual**: Resolve + build completed in ~55s on this machine (deps largely cached from prior MK work). Explicit `name: "ManifoldKit"` path package worked first try. No Package.swift footguns.
- **Resolution**: N/A — smooth.
- **Category**: API-ERGONOMICS
- **Severity**: papercut (positive)

---
