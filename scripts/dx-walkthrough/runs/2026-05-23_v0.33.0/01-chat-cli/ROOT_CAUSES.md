# Root-cause analysis — chat-cli walkthrough findings

The 3-run walkthrough surfaced surface-level bugs (two one-line fixes) and pointed at deeper structural patterns. The fixes alone won't prevent the same shape of bug from returning. This is the analysis the SUMMARY didn't have room for.

## The single deepest root cause

**MK already has a snippet-compilation gate (`readme-snippets.yml`) that *explicitly excludes* `swift,no-build`-tagged blocks** (`scripts/extract-snippets.sh:174-180`). The broken QUICKSTART CLI snippet was tagged `swift,no-build`, so the gate skipped it by design. Run-2 caught the smell directly: *"The snippet is fenced `swift,no-build` which suggests it might be non-compiling pseudo-code."* It is — by policy.

The policy is reasonable in the abstract (some snippets are deliberate illustrations of types/fragments that cannot stand alone), but it has been over-applied to **copy-paste targets** — the snippets that are the user's hello-world. Once a copy-paste target is fenced `no-build`, it can drift indefinitely. Both unanimous findings (F1 broken `stream` iteration, F5 ambiguous `[("user", "Hello")]`) live behind that `no-build` tag.

This is the root cause behind 2 of 3 unanimous findings, and the structural reason this category of bug survives.

## Pattern map

| Surface bug | Category | Deeper pattern |
|---|---|---|
| F1: `for try await event in stream` doesn't compile | DOC-WRONG | `no-build` covers copy-paste targets |
| F2: Swift 6.1 floor ≠ `.v26` platform floor | DOC-WRONG | README requirements drift independently of `swift-tools-version` ceiling rule in CLAUDE.md |
| F3: No headless quickstart at the top | DOC-MISSING | README "hello world" is SwiftUI-only; CLI/server use cases are afterthoughts |
| F4: Backend factories not enumerated | DOC-MISSING | Backend discoverability is mediated by knowing the umbrella entry points (`DefaultBackends`, `loadCloudBackend`), not a published list |
| F5: `[("user", "Hello")]` tuple ambiguous | DOC-WRONG | Same `no-build` policy as F1 |
| F6 (all runs): "Foundation Models is the only backend new users find" | API-DISCOVERABILITY | The single visible factory in QUICKSTART becomes the de facto default |

## Three root causes

### 1. `swift,no-build` is overloaded

Today the tag conflates three different things:

- **Genuinely partial** — a fragment showing a type or method signature without surrounding context (legitimate)
- **Package.swift fragment** — already auto-skipped separately by the extractor
- **"I haven't gotten around to making this compile"** — the failure mode

Without a policy distinguishing these, `no-build` becomes the path of least resistance for any non-trivial snippet, including the ones users will actually paste. The longer this drift continues, the more F1-shaped bugs accumulate behind the tag.

**Fix shape**: Replace `no-build` with two narrower tags:
- `swift,illustrative` — explicitly partial, never the hello-world for any flow
- `swift,wip` — temporary, must be removed before merge; CI fails on its presence on main

Or simpler: keep `no-build`, but add a lint that fails CI if a `no-build` block appears in any section heading containing "Bring your own", "Quick start", "Getting started", "Hello world", or "CLI". Those headings are *contracts* that the content is copy-pasteable.

### 2. README's "Requirements" is hand-maintained and out of sync with `Package.swift`

`Package.swift` declares the actual swift-tools-version; README's "Requirements" section restates it in prose. There is no test that those agree, so they drift. CLAUDE.md has an explicit rule about the tools-version ceiling (`swift-tools-version ceiling = installed Xcode toolchain`), but no rule about the **floor** matching what the README advertises.

**Fix shape**: Add a one-line check to `check-readme.sh` (already invoked from `readme-snippets.yml`) that greps the stated Swift version out of README and asserts it matches the `// swift-tools-version:` line in `Package.swift`. Two lines of bash.

### 3. Headless/CLI is a second-class flow in the docs

Three independent agents all built CLIs and all reported the same orientation problem: README's hello-world is SwiftUI; the CLI recipe is buried in a "Bring your own UI" subsection. This biases every new evaluator toward the SwiftUI path even when their actual use case is headless. It also means the headless path's snippets get less reader-pressure to compile cleanly — they're nobody's main read.

This explains why all three agents picked Foundation Models (the only backend with a one-liner in the BYO-UI subsection). They never made it deep enough to find anything else.

**Fix shape**: A `docs/QUICKSTART-CLI.md` (or top-level section) with a complete `Package.swift` + `main.swift`, exercised in the snippet gate. Promote it from the README — "If you're building a CLI / server, start here →". This costs ~50 lines of markdown and earns back the orientation problem in one move.

## Why this is worth more than the two doc fixes

The two one-line fixes from PR #1392 close F1 and F2 today. They do nothing for the next snippet that's tagged `no-build` because someone didn't want to wrestle with the gate. The structural fixes above are the only thing that prevents this exact shape of bug from coming back in two months.

In particular: **F1 ("for-in loop requires GenerationStream to conform to AsyncSequence") survived from the moment the BYO-UI subsection was added until 2026-05-23**. We don't know when that was, but the snippet gate (`readme-snippets.yml`) has been in place since "Wave D-C1 of the DX overhaul" per the workflow header, and it has *never* caught this bug because the bug is on the other side of the `no-build` tag the whole time. The gate is well-designed; its scope is the problem.

## Meta-finding about the methodology itself

The walkthrough produced 6+ friction entries per run with a 30-minute budget against the smallest possible archetype. The cost was 3 agent runs (~25 min wall-clock total since parallel) plus ~10 min of dispatch + synthesis. The signal-to-noise on the top findings was extremely high — 3/3 concordance on both top items.

The single most useful constraint was **forbidding source access**. Two of the three agents flagged the moment they wanted to grep MK internals; that moment is the friction the docs were supposed to absorb. Without the rule, the agents would have read the source, found `stream.events` in 30 seconds, and reported "no friction."

This suggests the walkthrough is a **repeatable, low-cost release-gate-or-quarterly-audit shape**, not a one-off. The archetypes (CLI → SwiftUI → agentic) form a natural difficulty ladder that exercises progressively more of the public API. Re-running after fixes is the highest-leverage validation step in the loop.

## Actionable next steps, ranked

1. **Tighten `no-build` policy** (highest leverage — closes the structural root cause of F1, F5, and most future doc-wrong findings)
2. **README↔Package.swift Swift floor agreement check** (2-line bash, closes F2 forever)
3. **First-class headless quickstart** (closes F3, F4, F6 — and unblocks the next archetype, which won't make sense without it)
4. **Re-run chat-cli archetype** to confirm the doc fixes landed and detect any new friction surfaced now that the top items are gone
5. **Draft archetype 2** (SwiftUI chat) — different layer, will surface different bugs
