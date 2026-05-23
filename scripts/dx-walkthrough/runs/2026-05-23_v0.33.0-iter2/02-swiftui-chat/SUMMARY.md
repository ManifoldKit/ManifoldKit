# swiftui-chat archetype — iteration 2 (post-#1411, post-#1417)

**Date**: 2026-05-23
**MK version**: 0.33.0 + PR #1411 + PR #1417
**Agent model**: Opus 4.7 (all 3 runs)
**Outcome**: 1/3 reached a launching app with persistence verified (run-3); 0/3 reached fully-working multi-session chat with token streaming.

Run-3 completed end-to-end after a delayed wake — verified persistence via direct sqlite inspection (`~/Library/Application Support/com.dxwalkthrough.chat/store.sqlite`: same row, same Z_PK, same `ZCREATEDAT` across quit+relaunch, no duplicate auto-create). Runs 1 and 2 stalled mid-build; their logged friction is still signal but partial.

## Confirmed fixes

- **A2-F4 (session auto-create) — CLOSED.** Run-3 Entry 1 explicitly noted: *"`docs/QUICKSTART.md` did exactly [what was needed] — full `@main MyChatApp` example with `ManifoldKit.quickStart()`, `ChatView`, `.modelContainer(result.bootstrap.modelContainer)`, and an explicit note that session bootstrap auto-creates an empty session. Resolution: No friction; copy-paste-ready."* The single-session happy path that iter-1 found broken now works.
- **A2-F8 partial.** BuildingAChatUI.md no longer fails on sync-call-of-async-method, but introduced/preserved a new issue (see A2-iter2-F1 below).

## New findings

### A2-iter2-F1 — BuildingAChatUI.md teaches a fictitious `AppRuntime.make()` API [run-2, major]

The article (rewritten in PR #1417 to fix the original sync-from-async-context bug) now calls `AppRuntime.make(inferenceService:)` in its scaffold. There is no such public type — the article comment says *"AppRuntime lives in your app composition root,"* meaning it's a host-supplied placeholder. But the article never shows **how to actually construct a `ChatRuntimeBootstrap`** in a real app from the shipped `ManifoldBootstrap`. The reader is told the result is *"a `ChatRuntimeBootstrap`-typed runtime"* and to feed it into `chatVM.configure(runtime:)`, but the bridge is hand-waved.

The new shape compiles when no-build-tagged (which it is), but it doesn't teach the reader anything actionable. The first walkthrough agent following the article literally had to guess that `try await ManifoldBootstrap.build(...)` returns something they can pass directly. That's not a guess a doc-reader should be making.

**Fix shape**: replace the `AppRuntime.make(...)` placeholder with the actual `ManifoldBootstrap.build(...)` shape, and show the consumer how to extract the `ChatRuntimeBootstrap` from it (or document that `ManifoldBootstrap` *is* a `ChatRuntimeBootstrap`).

### A2-iter2-F2 — Article's sync-`init()` shape mismatches the realistic async bootstrap [run-2, major]

Companion to F1. The article's `init()` calls `AppRuntime.make(...)` synchronously, training the reader to expect a sync helper. The shipped equivalent (`ManifoldBootstrap.build(...)`) is `try await`. A faithful adopter either:
- Has to bootstrap inside `.task { }` on the root view (deviates from the article's "single bootstrap in App.init()" pitch), or
- Hacks `Task.sync`-style blocking (anti-pattern), or
- Discovers (via source-diving) a hypothetical sync helper that doesn't appear in public docs.

The article's "Migrating" section repeats the same sync shape — so this isn't a one-off slip, it's the canonical pattern.

### A2-iter2-F3 — No documented bridge from `quickStart()` to multi-session UI [run-3, major]

`docs/QUICKSTART.md` mentions `SessionManagerViewModel` once: *"The full session-management surface (list sidebar, create/delete/rename) lives on `SessionManagerViewModel` — see `Example/Advanced` for the worked example."*

But there is no documented bridge between `QuickStartResult` and `SessionManagerViewModel`. The consumer needs:
- A way to extract the same runtime/inference handles `quickStart()` already built, OR
- An equivalent of `quickStart()` that also returns a session manager, OR
- A documented pattern of constructing the session manager from `result.bootstrap.<something>`.

Run-3 verdict: *"Multi-session UI requires either dropping to `ManifoldBootstrap.build(...)` directly (which the docs allow but don't show end-to-end) or being told that `QuickStartResult` already contains the needed handles — neither is documented."*

**Fix shape**: extend `QuickStartResult` with a `sessionManager: SessionManagerViewModel` property, OR add a docs section "Adding the session sidebar to your quickStart app" that shows the construction explicitly.

### A2-iter2-F4 — `QuickStartResult` public shape not documented [run-3, major]

README and MinimalExample only demonstrate `result.viewModel` and `result.bootstrap.modelContainer`. The full set of fields on `result.bootstrap` (runtime? inferenceService? sessionStore? messageStore? endpointStore?) is only discoverable by reading `Sources/ManifoldKit/QuickStart.swift` — which the walkthrough explicitly forbids.

This is a 5-minute DocC fix: add a `## Topics` section to a curated page listing `QuickStartResult` and `ManifoldBootstrap`'s public fields.

### A2-iter2-F6 — SwiftPM-only run requires manual .app bundling on macOS [run-3, major]

Run-3 confirmed: a SwiftPM `.executableTarget` containing `@main struct App: App` builds, but **`swift run` produces a binary that silently refuses to open a window**. SwiftUI on macOS requires the binary to be inside a bundled `.app` with an `Info.plist` containing `NSPrincipalClass=NSApplication`. Running a raw SwiftPM executable produces no error, no window — just a long-running process that does nothing visible.

To make `quickStart()` actually show a window, run-3 had to:
1. Hand-roll an `Info.plist`
2. Copy the executable into `DXChatApp.app/Contents/MacOS/`
3. Ad-hoc codesign
4. Hit a dyld error: `Library not loaded: @rpath/llama.framework/...`
5. Copy `llama.framework` into `DXChatApp.app/Contents/Frameworks/`
6. `install_name_tool -add_rpath @loader_path/../Frameworks` + re-codesign

**~6 manual steps**, none documented. `MinimalExample` sidesteps via `ManifoldExamples.xcodeproj` (Xcode bundles automatically). Any SwiftPM-only consumer hits this.

This is a sharper restatement of F5: not just "no scaffolding guidance" but "the obvious SwiftPM path doesn't actually run a SwiftUI app on macOS, period."

**Fix shape**: prominently document in QUICKSTART that SwiftUI apps need either (a) an Xcode project / xcodegen path, or (b) the manual `.app` bundling dance. Ideally provide a tiny script or template that does the bundling.

### A2-iter2-F7 — "Browse Models" CTA is still inert even with `ManifoldUIModelManagement` imported [run-3, major]

Concordance with iter-1 A2-F5, but worse than expected: run-3 imported `ManifoldUIModelManagement` (the non-default module that contains `ModelManagementSheet`) and added the product dep, expecting the empty-state "Browse Models" button to wire up automatically. It didn't. Programmatic AX click confirmed `clicked button 1` but no sheet appears.

QUICKSTART/DocC don't explain the actual wiring required. `ChatView(showModelManagement:)`'s `showModelManagement` binding appears to be for the API-key sheet only, not for `ModelManagementSheet`. There's no documented path from "I called `quickStart()`" to "the model browser sheet opens on Welcome state click."

**Fix shape**: either auto-wire `ModelManagementSheet` when `ManifoldUIModelManagement` is linked, OR document the explicit binding consumers must add. The current state is a dead button with no recoverable user flow.

### A2-iter2-F5 — No SwiftPM-only scaffolding instructions [run-1, major]

QUICKSTART says *"Xcode 16+"* and *"a SwiftUI app target on iOS 18+ / macOS 15+"* but only `MinimalExample` shows the actual scaffolding — via `xcodegen` + `project.yml`. A consumer evaluating MK with **just** SwiftPM (no Xcode project files, no xcodegen) has no documented path to a SwiftUI app target.

Notable: a bare SwiftPM `.executableTarget` containing `@main struct App: App` builds, but `swift run` produces a CLI binary with no Info.plist or bundle — SwiftUI window/persistence/`.modelContainer` lifecycle is at best fragile, at worst silently broken on macOS.

**Fix shape**: add a "SwiftPM-only scaffolding" callout to QUICKSTART.md pointing at either the xcodegen path or Xcode's File→New→Project SwiftUI App template. This is a brief paragraph, not a full subsection.

## Concordance map

| Finding | Runs | Severity | Type |
|---|---|---|---|
| A2-iter2-F1 BuildingAChatUI uses fictitious AppRuntime | 1/3 | major | DOC-WRONG |
| A2-iter2-F2 Article sync-init mismatches async bootstrap | 1/3 | major | DOC-WRONG |
| A2-iter2-F3 No quickStart → SessionManager bridge | 1/3 | major | DOC-MISSING / API-GAP |
| A2-iter2-F4 QuickStartResult shape undocumented | 1/3 | major | DOC-MISSING |
| A2-iter2-F5 No SwiftPM-only scaffold guidance | 1/3 | major | DOC-MISSING |

The findings are disjoint (each run hit a different layer), which is the expected shape when the methodology is working — each agent's path reveals a different next-layer-down issue.

## Iteration delta

| Iter | Working | Blockers | Major findings |
|---|---|---|---|
| 1 (baseline) | 1/3 fully (2/3 stuck at no-session) | A2-F4 (no session creation) | 6 (F4, F5, F6, F7, F8, F9) |
| 2 (post #1411, #1417) | 0/3 fully (1/3 confirmed single-session works; 2/3 stalled mid-build) | 0 | 5 (iter2-F1 through F5) |

**Single-session quickStart is solid. Multi-session SwiftUI is the next dominant gap.**

## Recommended next moves

### Highest leverage
1. **Fix BuildingAChatUI.md properly** — replace the `AppRuntime.make()` placeholder with the actual `ManifoldBootstrap.build(...)` shape and show how to extract `ChatRuntimeBootstrap` from it (closes iter2-F1 + iter2-F2 in one PR). PR #1417's rewrite was structurally correct but didn't go far enough.

### Documentation
2. **Add `SessionManagerViewModel` to QuickStartResult** OR document the bridge — closes iter2-F3. This is the analogue of A2-F4: "the documented happy path provides only single-session; multi-session requires source-diving." Fix is structurally the same: ship the bridge, or document it.
3. **DocC `## Topics` curation** for `QuickStartResult` and `ManifoldBootstrap` (iter2-F4). 10 minutes of DocC work.
4. **SwiftPM scaffolding callout** in QUICKSTART (iter2-F5). One paragraph.

### Methodology
5. **The 60-min budget is still too tight for the SwiftUI archetype on this hardware.** Cold builds eat 5-10 min, leaving ~50 min for code + verification. Two of three agents stalled mid-build before completing acceptance criteria. Consider bumping to 90 min or warming the build cache via a different mechanism than the broken symlink trick (e.g. pre-resolve MK's deps as a brief precondition the human can do once).

## Verdict

PR #1411 closed the iter-1 blocker cleanly. PR #1417 partially closed iter-1 A2-F8 but introduced new doc-wrong-shape issues by leaving the `AppRuntime.make()` placeholder in place. The next iteration of MK's SwiftUI DX needs to **stop teaching fictitious APIs** in BuildingAChatUI.md — that's the headline of this round.

The framework continues to work; the docs continue to under-deliver for anything past the most minimal hello-world.
