# chat-cli archetype — 3-run synthesis

**Date**: 2026-05-23
**MK version**: 0.33.0
**Agent model**: Opus 4.7 (all 3 runs)
**App outcome**: 3/3 runs produced a working CLI streaming real tokens

## Backend choice — 3/3 picked Foundation

None of the three agents went near Ollama or any of the local GGUFs, despite the brief listing them. They all anchored on `QUICKSTART.md`'s `.builtInFoundation` example because it's the only backend with a copy-pasteable factory call in the public docs. **This is itself a finding**: backend discoverability is so skewed toward Foundation that the rest of MK's backend surface is effectively invisible to a new developer reading docs alone.

## Unanimous findings (3/3 runs, all top-3)

### F1 — QUICKSTART "Bring your own UI" snippet does not compile [BLOCKER → MAJOR]

`for try await event in stream { ... }` — but `GenerationStream` is not an `AsyncSequence`. Correct form is `for try await event in stream.events`. All three agents hit this; run-2 escalated to blocker. Two found it by reading tests / source, one guessed.

Fix: one-line change in `docs/QUICKSTART.md`. Consider compile-testing snippets via the cold-start gate.

### F2 — README's stated Swift floor (6.1) is incompatible with its own platform floor (.v26) [MINOR]

`PackageDescription.SupportedPlatform.MacOSVersion.v26` requires tools-version 6.2. README "Requirements" section says 6.1+ is sufficient. Every fresh consumer hits this immediately.

Fix: bump the README requirement to 6.2.

## Strongly corroborated (2/3 runs)

### F3 — No headless/CLI quickstart [MINOR → MAJOR]

The only CLI-shaped example is the "Bring your own UI" subsection at the bottom of QUICKSTART, fenced `swift,no-build`. README opens with SwiftUI `ChatView` as the canonical hello world. A developer evaluating MK from a terminal has to scroll past four screens of SwiftUI views to find anything they can run.

Fix: add a top-level "CLI / headless" recipe with a complete `Package.swift` and `main.swift`. Compile-test it.

## Notable single-run findings

### F4 (run-2) — Backend factory enumeration is invisible [MAJOR]

"Which `.builtIn*` / `.cloud(...)` factories exist? How do I target Ollama at localhost?" DocC lists `loadModel(from:plan:)` symbols but the public markdown doesn't enumerate backend factories. Agent could not pick a non-Foundation backend from docs alone.

Fix: docs page listing all public backend factories with one-line examples.

### F5 (run-2) — `generate(messages: [("user", "Hello")])` is ambiguous [MAJOR]

Is the tuple literal the real signature, or pseudo-code? The `swift,no-build` fence implies pseudo-code, but it happens to be real. No type signature shown adjacent.

Fix: replace pseudo-code-fenced examples with compile-tested ones; show the type signature once.

## Methodology check — does the run produce signal?

Yes. With n=3 and ~30-min budgets, two findings reached 3/3 concordance and were the agents' top-severity entries each time. The single-run findings are still useful as exploration breadcrumbs even without corroboration. The forced-blindness rule (no reading `Sources/Manifold*/**`) held — all three agents flagged the moment they wanted to grep internals, which is exactly the signal we wanted to capture.

## Recommended fixes, ranked by leverage

1. Fix `stream` → `stream.events` in `docs/QUICKSTART.md` (5 min, removes a blocker for every new CLI evaluator)
2. Bump README Swift requirement 6.1 → 6.2 (1 min)
3. Add a top-level CLI quickstart with compile-tested `Package.swift` + `main.swift` (1–2 hr)
4. Add a backend-factory enumeration page (1–2 hr)
5. Make a CI step that compiles the snippets in `docs/QUICKSTART.md` (the existing cold-start gate is the natural home — currently the snippet is `swift,no-build` which is the root cause of F1 and F5 surviving this long)

## Re-running this experiment

- Same brief verbatim (`briefs/01-chat-cli.md`)
- New run directory `runs/<date>_<version>/01-chat-cli/run-N/`
- Diff `FRICTION.md` across versions to confirm fixes landed and to surface regressions
- 3 runs is the floor; 5 would be better if budget allows
