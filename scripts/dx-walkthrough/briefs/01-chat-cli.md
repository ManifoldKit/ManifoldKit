# Brief: Chat CLI with ManifoldKit

You are a Swift developer who has just heard about **ManifoldKit** — a Swift framework for building local-first AI chat apps. You want to build a small terminal chat CLI to evaluate it.

## What you're building

A macOS terminal program that:

1. Loads a local language model via ManifoldKit
2. Reads a user prompt from stdin (one line at a time)
3. Streams the model's response to stdout token-by-token
4. Loops until the user hits Ctrl-D
5. Exits cleanly (no warnings, no hangs)

## Constraints

- **Target**: macOS 26, Swift 6, `swift run` from the terminal
- **You may read**: ManifoldKit's `README.md`, anything under `docs/`, anything under `Sources/*/Documentation.docc/`, the package's `Package.swift`, and any public-facing markdown in the repo root.
- **You may NOT read**: ManifoldKit's source files (`Sources/Manifold*/**/*.swift`) OR its test files (`Tests/**`). If you find yourself wanting to grep MK internals or peek at how tests construct types, **stop and log it in FRICTION.md** as a discoverability gap, then try to work around it from the public docs alone. This is the whole point of the exercise — we're testing whether the *public-facing* docs and API are sufficient. Tests are technically public but they're not where new developers should be reverse-engineering the API from.
- **Backend choice is yours.** The user's machine has Ollama running at `localhost:11434` and several GGUF files on disk under `~/Documents/Models/`. You can also try MLX, Foundation, or any cloud backend. Pick whichever you can get working fastest from the public docs.
- **Budget**: ~30 minutes of focused work. If you're stuck on one problem for more than 3 substantive attempts, log it in FRICTION.md and pivot.

## Cold build time

A fresh consumer of ManifoldKit cold-builds all transitive dependencies (huggingface, MLX, llama, etc.). The first `swift build` can take 5–10 minutes on Apple Silicon depending on which trait set you opt into. Subsequent builds are cached and fast.

Don't be alarmed by long initial build times. Log it as friction if it bothers you, but the dependency tree is what it is.

## Working directory

Your app lives at `./app/` relative to wherever this brief is. Create a SwiftPM package there. Reference ManifoldKit via a local path dependency to the repo containing this brief — resolve the absolute path at run time. Use:

```swift
.package(name: "ManifoldKit", path: "<absolute path to the ManifoldKit repo containing this brief>")
```

(Per CLAUDE.md, `.package(path:)` needs an explicit `name:` to work reliably.)

## Required behavior (acceptance criteria)

- [ ] `swift run` from `./app/` starts the CLI without crashing
- [ ] You can type a prompt, press Enter, and see real model-generated tokens stream to stdout (not stubs, not echoes)
- [ ] You can send a second prompt and get a second response
- [ ] Ctrl-D exits cleanly
- [ ] The final `swift run` session is captured in `./session.log`

## Deliverables

In your run directory you should produce:

1. **`./app/`** — the working Swift package
2. **`./FRICTION.md`** — your friction log (template below). This is the most important deliverable. Even if the app works perfectly, the friction log is what we're measuring.
3. **`./session.log`** — output of your final successful `swift run` session, showing at least 2 prompt/response cycles
4. **`./NOTES.md`** — 5–10 lines: what backend you chose and why, what you'd want to build next, your overall impression of MK's DX

## FRICTION.md template

Start the file with this header, then append entries as you go. Log friction **as it happens**, not at the end — you will forget.

```markdown
# Friction log — chat-cli archetype

Agent: <your model name>
Date: 2026-05-23
ManifoldKit version: <from Package.swift or git tag>

---

## Entry 1
- **Trying to**: <what you were attempting>
- **Expected**: <based on docs / API names, what you thought would happen>
- **Actual**: <what happened — error, missing API, confusing behavior>
- **Resolution**: <how you got past it, or "gave up and pivoted">
- **Category**: DOC-MISSING | DOC-WRONG | API-DISCOVERABILITY | API-ERGONOMICS | API-GAP
- **Severity**: blocker | major | minor | papercut

## Entry 2
...
```

**Log liberally.** A papercut hit once is worth recording. A blocker is worth recording even if you eventually solved it — the resolution path matters.

## What we're trying to learn

This run will be compared against 2 other agents doing the same exercise, and across future MK versions. The goal is to surface:

- Documentation gaps (things a new developer needs to know that aren't documented)
- API discoverability problems (right API exists but couldn't be found)
- API ergonomics problems (right API found but painful to use)
- Outright API gaps (something a chat CLI fundamentally needs that MK doesn't expose)

**Be honest.** If the docs are great, say so. If something is genuinely confusing, say so without softening. Your friction log is data, not a critique — surface, don't sugarcoat.

## Reporting back

When done (or when time/attempts are exhausted), respond with:
- Whether the app works (yes/no/partially)
- Path to your run directory
- The 3 highest-severity friction entries, verbatim
- One-line overall verdict
