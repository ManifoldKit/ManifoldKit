# swiftui-chat archetype — iteration 1 (baseline)

**Date**: 2026-05-23
**MK version**: 0.33.0 (post-#1406)
**Agent model**: Opus 4.7 (all 3 runs)
**App outcome**: 1/3 reached fully-working chat with persistence; 2/3 compiled + launched + rendered ChatView but couldn't complete a chat session

## Coverage

Per the methodology lesson from archetype-1 iter-3, each agent was steered to a different surface:

| Run | Path | Outcome |
|---|---|---|
| 1 | `quickStart()` + drop-in `ChatView` (high-level) | Compiles, launches, ChatView renders → **stuck at "No session selected"** |
| 2 | Explicit `ManifoldBootstrap` + shipped `ChatView` (BYO bootstrap) | **Full end-to-end**: streamed Foundation Models tokens, 7+ persistent sessions |
| 3 | `quickStart(configuration:)` with bundleId, persistence focus | Compiles, launches, ChatView renders, persistence wired → **stuck at "Download a model"** |

The 1/3 success rate is misleading — run-2 succeeded because they had to **dive past the documented happy path** to wire session creation. They explicitly noted the canonical DocC article they were following doesn't compile as written.

## The headline finding

**A2-F4 (blocker): the documented happy path produces a non-functional binary.**

`quickStart()` + drop-in `ChatView` (the canonical "5-minute hello world") compiles, launches, and renders. The composer is then **disabled** with placeholder text "No session selected — Send a message to start chatting." There is no documented way to create a session through the high-level path. Session management lives in `SessionManagerViewModel` / `createSession()`, which exists only in `Example/Advanced/` and is mentioned **nowhere** in QUICKSTART.md or the MinimalExample README.

Both run-1 (deliberately following the high-level docs) and run-3 (persistence-focused) hit this. Run-3 attributed it to "no model auto-selected" and ran out of budget before discovering the deeper truth; run-1 dug further and found the actual cause.

This is the largest gap surfaced by any walkthrough so far. **The "minimal example" as shipped does not minimally work.**

## Findings

### A2-F4 — `quickStart()` ships a chat UI with no way to start a chat [2/3, BLOCKER]

Already detailed above. Fix needs to be one of:
- `quickStart()` auto-creates an initial session
- `ChatView` exposes a "New Chat" button wired to a documented session-creation API
- QUICKSTART.md explicitly documents the session-creation step

The first option is the cleanest contract: "the minimal example shows a working chat" should mean *working*.

### A2-F7 — `ManifoldBootstrap.build(...)` return type is an undocumented progress/task tuple [run-2, blocker]

```
(progress: AsyncStream<RuntimeBootstrapMilestone>, task: Task<ManifoldBootstrap, any Error>)
```

QUICKSTART says "drop down to `ManifoldBootstrap.build(...)` directly" without warning that the return is a tuple, without naming `RuntimeBootstrapMilestone`, and without showing how to consume either side. Run-2 reverse-engineered `try await result.task.value` from the compiler error alone — exactly the source-diving the brief was designed to surface.

**Fix shape**: document the tuple return, the `RuntimeBootstrapMilestone` cases, and a worked example showing both how to await the bootstrap and how to render progress. This is BuildingAChatUI.md's job and it's currently silent.

### A2-F8 — Canonical DocC article `BuildingAChatUI.md` does not compile as written [run-2, major]

Same shape as archetype-1 F1 (broken `stream.events` snippet): the doc snippet calls `chatVM.switchToSession(session)` synchronously in `App.init()` and `sessionVM.createSession()` synchronously in an `onChange` closure — both methods are `async`. The article can't compile because `App.init()` and `onChange` closures aren't async contexts.

This is **the exact pattern PR #1393 was supposed to prevent**. The snippet compile gate (`readme-snippets.yml`) extracts from `README.md`, `docs/QUICKSTART.md`, and `docs/QUICKSTART-CLI.md` — but **not from DocC catalogs** (`Sources/*/Documentation.docc/Articles/*.md`). DocC content is documentation but it's outside the gate.

**Fix shape**: extend `scripts/extract-snippets.sh` to also walk DocC `.docc` catalogs, OR add an explicit DocC snippet gate. Either way, the same `swift,no-build` policy that PR #1393 enforced should apply.

### A2-F9 — BYO chat views are blocked by missing public type docs [run-2, major]

`ChatViewModel.messages` exists in DocC but the element type isn't named in any DocC topic page. No DocC page for `Message` / `ChatMessage` / `MessageRecord`. Without the type name, writing `ForEach(chatVM.messages) { msg in ... }` is impossible without source-diving or autocomplete.

**Fix shape**: add the public message-record type to ManifoldRuntime/ManifoldInference's DocC `## Topics` table. One line in a curated page.

### A2-F5 — "Browse Models" empty-state button is bound to a dead handler [run-1, major]

`ChatView`'s built-in empty state shows a "Browse Models" button. The `showModelManagement` binding goes nowhere by default — the actual model browser (`ModelManagementSheet`) lives in `ManifoldUIModelManagement`, a non-default module that needs explicit product addition + `ModelManagementViewModel(huggingFaceService:downloadManager:)` construction + a `.sheet` modifier. None of this is in QUICKSTART. The button promises a flow it cannot deliver.

**Fix shape**: either remove the button from the empty state by default (and let consumers add it via API) or document the wiring as a required step in QUICKSTART. The current state is "the framework dares you to find this on your own."

### A2-F6 — `ChatViewModel.refreshModels()` scans the wrong directory by default [run-1, major]

A fresh evaluator with GGUFs at `~/Documents/Models/` (the chat-cli archetype's canonical location) finds 0 models. The default scan path is `<Application Support>/<bundleId>/<modelsDirectoryName>/` — documented in README "Where data lives" but not surfaced anywhere a SwiftUI evaluator would look. Cross-archetype inconsistency: the CLI evaluator's models are invisible to the SwiftUI app and vice versa.

**Fix shape**: document the default scan path prominently in the SwiftUI quickstart, OR have `ChatViewModel` scan a small set of common locations and surface them all.

### A2-F1 — `quickStart()` doesn't auto-select a model when one is available [3/3, minor]

When Foundation Models is available on macOS 26, `quickStart()` could theoretically auto-load it (it's free, on-device, no setup). Instead the ChatView shows "Welcome — Download a model to get started." A first-time evaluator with a perfectly capable backend already on disk sees a "no model" message.

**Fix shape**: have `quickStart()` opportunistically wire Foundation Models when available. Document the fallback chain.

### A2-F2 — MK-internal deprecation warnings reach SwiftUI consumers too [3/3, papercut]

Cross-archetype concordance with iter-4 F21: the `MLX.GPU.set(cacheLimit:)`, `default will never be executed`, and `configure(runtime:)` deprecations all surface at consumer build time. Run-2 specifically flagged `configure(runtime:)` is **deprecated yet taught as current API** somewhere in the docs.

### A2-F3 — SwiftPM bare executable doesn't restore window state [run-3, papercut]

Window/sidebar layout doesn't survive process kill+relaunch. Likely needs an Xcode `.app` target. Could be addressed with a one-line callout in the SwiftUI quickstart pointing at Xcode's SwiftUI App template.

## Cross-archetype patterns

| Archetype 1 | Archetype 2 | Pattern |
|---|---|---|
| F1 broken stream snippet | A2-F8 broken DocC article | **Compile-test gate not covering DocC catalogs** |
| F4 backend factory invisible | A2-F9 message type invisible | **DocC `## Topics` curation gaps** |
| F8 `@MainActor` shape-dependent | A2-F7 bootstrap tuple-return | **Public API shape not visible in docs** |
| F21 internal warnings leaking | A2-F2 same warnings | **Concordance: not archetype-specific** |

The shape of failures repeats across archetypes. The root causes are not specific to CLI or SwiftUI — they're about the docs system itself.

## Concordance map

| Finding | Runs | Severity | Type |
|---|---|---|---|
| A2-F4 quickStart can't chat | 2/3 | **blocker** | Behavioral gap |
| A2-F1 no auto-model-select | 3/3 | minor | DX gap |
| A2-F2 internal warnings | 3/3 | papercut | Concordance |
| A2-F7 bootstrap tuple-return | 1/3 | blocker | Doc gap |
| A2-F8 DocC article broken | 1/3 | major | Compile-gate gap |
| A2-F9 message type undocumented | 1/3 | major | DocC curation |
| A2-F5 dead "Browse Models" button | 1/3 | major | API gap |
| A2-F6 wrong default model scan dir | 1/3 | major | Doc/UX gap |
| A2-F3 SwiftPM window-state | 1/3 | papercut | Doc gap |

## Why the 1/3 success rate

The 2/3 failures are not because the agents were weaker — both correctly followed the documented happy path and hit a behavioural gap (no session creation) that the docs don't address. Run-2 succeeded because they explicitly chose to deviate from the high-level surface and dive into the lower-level `ManifoldBootstrap` + manual session wiring path, finding session creation through the `Example/Advanced/` demo code.

In other words: **the documented path doesn't work, but the framework underneath does.** Once you know what to wire, end-to-end works (streaming + persistence + multi-session) — but knowing what to wire requires reading sample code that QUICKSTART doesn't reference.

## Recommended next moves, ranked

### Behavioral fix (the actual blocker)
1. **A2-F4**: Make `quickStart()` create an initial session OR have `ChatView` expose a documented "New Chat" affordance. This is the difference between "the docs are incomplete" and "the docs are misleading." Run-1's verdict: *"the documented 5-minute SwiftUI happy path ships a runnable binary you cannot actually chat in."*

### Structural fix
2. **A2-F8**: Extend the snippet compile gate to cover DocC `.docc` catalogs (or apply the no-build policy to them via a separate check). This catches A2-F8 and the next BuildingAChatUI.md-shape bug before it ships.

### High-leverage docs
3. **A2-F7**: Document `ManifoldBootstrap.build`'s tuple return, `RuntimeBootstrapMilestone`, and the await pattern. One DocC page closes a blocker for any BYO bootstrap consumer.
4. **A2-F9**: Curate `Message` (or whatever the messages-array element is) into ManifoldRuntime's DocC `## Topics`. One line.

### Single-line fixes
5. **A2-F5**: Default off the dead "Browse Models" button, OR document the wiring.
6. **A2-F6**: Document the default model scan directory in the SwiftUI quickstart.
7. **A2-F1**: Have `quickStart()` opportunistically wire Foundation Models on macOS 26.
8. **A2-F3**: SwiftPM-vs-Xcode-bundle window-state callout.
9. **A2-F2**: Continue the F21 trait-gate / source-cleanup work.

## Verdict

Archetype-1 iter-1 found a broken hello-world snippet. **Archetype-2 iter-1 found a hello-world *binary* that doesn't work.** The framework underneath is solid — once wired correctly, streaming + persistence + multi-session all "just work." But the docs path documented for new users leads to a dead end.

This is a bigger problem than any single chat-cli iteration uncovered. It's also exactly the kind of finding the walkthrough methodology was designed to surface: end-to-end runtime behavior that internal tests don't see and that fresh-eyes consumers hit immediately.

**The methodology has a new question to answer**: how many iterations does it take to fix A2-F4? My prediction (from the archetype-1 pattern) is one focused PR to add session-creation to `quickStart()` + a doc update; the rerun will reveal what's hiding behind it.
