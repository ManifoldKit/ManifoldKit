# Brief: SwiftUI Chat App with ManifoldKit

You are a Swift developer who has just heard about **ManifoldKit** — a Swift framework for building local-first AI chat apps. You want to build a minimum-viable SwiftUI macOS app to evaluate it before committing to it for a larger project.

## What you're building

A native macOS SwiftUI app that:

1. Launches a window showing a chat interface
2. Lets the user pick a model (any documented backend — Foundation Models, a local GGUF, or an Ollama endpoint — your choice)
3. Streams responses in the UI as they generate
4. **Persists chat sessions across launches** — closing and reopening the app should restore prior conversations
5. Lets the user start a new session and switch between sessions

If MK provides a drop-in `ChatView` that handles all of this, use it. If you have to assemble pieces, do that. The goal is a working SwiftUI app, not a particular code shape.

## Constraints

- **Target**: macOS 26, Swift 6, SwiftUI
- **You may read**: ManifoldKit's `README.md`, anything under `docs/`, anything under `Sources/*/Documentation.docc/`, the package's `Package.swift`, repo-root markdown, the existing `Example/Examples/MinimalExample/` directory if one exists (this is canonical sample code, fair game).
- **You may NOT read**: ManifoldKit's source files (`Sources/Manifold*/**/*.swift`) OR its test files (`Tests/**`). If you find yourself wanting to grep MK internals or peek at how tests construct types, **stop and log it in FRICTION.md** as a discoverability gap, then try to work around it from the public docs alone.
- **Budget**: ~60 minutes of focused work. If you're stuck on one problem for more than 3 substantive attempts, log it in FRICTION.md and pivot.

## Cold build time

A fresh consumer of ManifoldKit cold-builds all transitive dependencies (huggingface, MLX, llama, etc.). The first build can take 5–10 minutes. Plan accordingly; subsequent builds are cached.

## Working directory

Your app lives at `./app/` relative to wherever this brief is. Reference ManifoldKit via a local path dependency to the repo containing this brief — resolve the absolute path at run time:

```swift
.package(name: "ManifoldKit", path: "<absolute path to the ManifoldKit repo containing this brief>")
```

(Per CLAUDE.md, `.package(path:)` needs an explicit `name:` to work reliably.)

## Required behavior (acceptance criteria)

- [ ] App compiles cleanly (warnings allowed, errors not)
- [ ] App launches and shows a SwiftUI window
- [ ] A chat interface is visible (input field, message list — drop-in `ChatView` or your own)
- [ ] You can verify in some way that a generation works end-to-end (screenshot, log, or stdout proof that tokens stream from a backend)
- [ ] After closing and relaunching the app, prior chat sessions remain visible

You do not need to make the UI pretty. You do need to verify it works — capture a screenshot via `xcrun screencapture` or equivalent, or a launch log showing the window opened and a backend loaded.

## Deliverables

In your run directory you should produce:

1. **`./app/`** — the working Swift package or Xcode project
2. **`./FRICTION.md`** — your friction log (template below). **This is the most important deliverable.**
3. **`./session.log`** — output of your final build + launch session, plus any captured screenshots referenced by filename
4. **`./screenshot.png`** (if possible) — screencapture of the running app
5. **`./NOTES.md`** — 5–10 lines: what backend/path you picked, what worked smoothly, what was surprising, your overall impression of MK's SwiftUI DX

## FRICTION.md template

Start the file with this header, then append entries as you go. Log friction **as it happens**, not at the end — you will forget.

```markdown
# Friction log — swiftui-chat archetype

Agent: <your model name>
Date: 2026-05-23
ManifoldKit version: <from version.txt or git tag>

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

**Log liberally.** A papercut hit once is worth recording. A blocker is worth recording even if you eventually solved it — the resolution path matters. Surfaces of interest in this archetype that didn't apply to the CLI version:

- The `ManifoldKit.quickStart()` flow vs explicit `ManifoldBootstrap`
- SwiftData container setup and the `.modelContainer(...)` modifier
- `ChatViewModel` and `ModelRegistry` access patterns
- Whether `ChatView` is the right entry point or whether BYO views are needed
- How sessions persist (do they just work? do you have to wire a store?)
- Whether the umbrella `import ManifoldKit` covers everything you need

## What we're trying to learn

This is the second archetype in a DX walkthrough series. Archetype 1 (chat-cli) is shipping; we want to know whether the SwiftUI happy path is comparably polished or whether different friction layers surface here.

**Be honest.** If the docs are great, say so. If something is genuinely confusing, say so without softening.

## Reporting back

When done (or when time/attempts are exhausted), respond with:
- Whether the app works (yes/no/partially) — note specifically: does persistence work?
- Path to your run directory
- The 3 highest-severity friction entries, verbatim
- One-line overall verdict
