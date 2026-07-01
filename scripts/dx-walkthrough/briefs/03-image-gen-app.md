# Brief: LocalImage — Designer-to-App, Voice + Image Generation (macOS)

You are a Swift developer who has just heard about **ManifoldKit** — a Swift framework for building local-first AI apps on Apple platforms. Until now you've mostly seen it pitched as a chat framework. A designer has handed you a brief and a runnable flow file for a small voice-driven image-generation app, and you want to evaluate whether ManifoldKit is the right foundation to build it on.

This is a **vibe-coding** exercise: you're given a designer brief and a visual flow, and your job is to bring it to life as a working SwiftUI app using ManifoldKit's public surface. You're not extending ManifoldKit — you're consuming it.

## What you're building

**LocalImage** — a native SwiftUI **macOS** app (the design is iPhone-first; you'll implement it as mac for this phase — physical iPhone is phase 4) that:

1. Greets the user on first launch with a clear "we need to download a model" moment, downloads a diffusion model, and persists it locally
2. Lets the user describe an image **by voice** (speech-to-text into the prompt field) or by typing
3. Generates a 768×768 image on-device via MLX diffusion
4. Shows the generated image at full prominence with Save / Try again / Refine actions
5. Keeps a history of prompts + generated images across launches

Voice is **required**, not a stretch goal — this phase exists to exercise both the image-generation and voice surfaces of ManifoldKit. If you can't get voice working from the public docs, log it as a blocker in FRICTION.md and pivot to text-only — but make sure the friction is captured, because that's the signal we're after.

## The design inputs

All design inputs live in `./design-assets/` (sibling directory to this brief):

1. **`DESIGN-BRIEF.md`** — prose design brief: product vision, target user (non-technical, Canva-style), the journey across first-launch / prompt / generation / result, and what's intentionally left open.
2. **`LocalImage Flow.html`** — runnable React/Babel iPhone-framed flow viewer. Open in a browser to see the rendered flow:
   ```
   open scripts/dx-walkthrough/briefs/03-design-assets/"LocalImage Flow.html"
   ```
3. **`screens.jsx`** — the underlying screen source. Every screen is a named React component with concrete copy, layout, and state. Read this directly; it's more reliable than trying to render the HTML headlessly.

Screens defined in `screens.jsx`: `FirstLaunch`, `Download`, `EmptyPrompt`, `VoiceListening`, `Generating`, `Result`, `HistoryChat`, `HistoryFeed`, error states (`ErrorDownload`, `ErrorGeneration`, `ErrorBlocked`), `ActionSheet`, plus `IPad` and `Mac` layout variants. The `Mac` variant is your primary visual reference for this phase.

Treat these as a real design handoff. Your job is to make the app feel like the brief and the flow describe, using ManifoldKit's public surface.

## Constraints

- **Target**: macOS 26, Swift 6, SwiftUI. Native macOS app (not Catalyst).
- **You may read**:
  - ManifoldKit's `README.md`, anything under `docs/`, anything under `Sources/*/Documentation.docc/`, the package's `Package.swift`, repo-root markdown
  - The `Example/Examples/MinimalExample/` directory if one exists
  - Everything in `./design-assets/` (HTML + JSX + DESIGN-BRIEF.md)
- **You may NOT read**:
  - ManifoldKit's source files (`Sources/Manifold*/**/*.swift`) or its tests (`Tests/**`). The whole point is testing whether the *public* surface is sufficient.
  - Any other implementation of LocalImage you happen to find on this machine. If you spot one, log the temptation in FRICTION.md and stay out of it.
- **Backend choice**: image gen runs on the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package (the local-inference families moved out of core in v0.48) — `FluxDiffusionBackend` (FLUX.1 Schnell) or `MLXDiffusionBackend` (SDXL Turbo / SD 2.1 Base), both conforming to `ImageGenerationBackend`. Add the `manifold-mlx` package and `import ManifoldMLX`; the value types (`ImageGenerationConfig`/`ImageGenerationEvent`) stay in core via `import ManifoldInference`. See [`docs/QUICKSTART-IMAGE-GEN.md`](../../../docs/QUICKSTART-IMAGE-GEN.md). For text input alongside the prompt composer, you may or may not need an LLM backend — read the design brief and decide. For voice, look at what ManifoldKit's voice module offers.
- **Budget**: ~90 minutes of focused work. The first-run download will eat real wall-clock time — that's part of the test. If you're stuck on one problem for more than 3 substantive attempts, log it in FRICTION.md and pivot.
- **Models**: the first-run download path is part of what we're testing. Let it run end-to-end if you can. If you find documented helpers to seed a model from disk, use them and log how discoverable they were.

## Cold build time

A fresh consumer of ManifoldKit cold-builds all transitive dependencies (huggingface, MLX, llama, etc.). The first `swift build` can take 5–10 minutes on Apple Silicon. Don't be alarmed; log it as friction if it bothers you, but the dependency tree is what it is.

## Working directory

Your app lives at `./app/` relative to wherever this brief is invoked from (typically inside a `runs/<date>_<tag>/03-image-gen-app/` directory). Create a SwiftPM package or Xcode project there. Reference ManifoldKit via a local path dependency to the repo containing this brief — typically two directories up from the brief, but resolve the actual path at run time:

```swift
.package(name: "ManifoldKit", path: "<absolute path to the ManifoldKit repo containing this brief>")
```

(Per CLAUDE.md, `.package(path:)` needs an explicit `name:` to work reliably.)

## Required behavior (acceptance criteria)

- [ ] App compiles cleanly (warnings allowed, errors not)
- [ ] App launches and shows a SwiftUI window
- [ ] First-run: app surfaces a clear "model needed" state and either downloads a diffusion model or lets the user point at a local one
- [ ] **Voice input works**: user can tap a mic affordance, speak a prompt, and see the transcription land in the prompt field. (If voice can't be made to work from public docs, that's a finding — log it.)
- [ ] Generation produces a 768×768 image on success (capture a screenshot)
- [ ] After closing and relaunching the app, prior prompts + images are still visible
- [ ] At least one of: Save / Try again / Refine actions on a generated image

You do not need to match the design pixel-for-pixel. You do need the **shape** of the journey to match the brief: first-run → prompt (voice or text) → waiting state → reveal → history. Capture a screenshot of each state via `xcrun screencapture`.

## Deliverables

In your run directory you should produce:

1. **`./app/`** — the working Swift package or Xcode project
2. **`./FRICTION.md`** — your friction log (template below). **This is the most important deliverable.**
3. **`./session.log`** — final build + launch output, plus any captured screenshots referenced by filename
4. **`./screenshots/`** — at least one screenshot of the running app (first-run, prompt, generated image)
5. **`./NOTES.md`** — 10–15 lines: which backend/path you picked, what felt like a chat-framework-trying-to-do-image-gen, where the design brief outran what MK's public surface supports, your overall verdict on MK as a foundation for non-chat apps

## FRICTION.md template

Start the file with this header, then append entries as you go. Log friction **as it happens**, not at the end — you will forget.

```markdown
# Friction log — image-gen-app archetype (phase 3, macOS)

Agent: <your model name>
Date: <run date>
ManifoldKit version: <from version.txt or git tag>

---

## Entry 1
- **Trying to**: <what you were attempting>
- **Expected**: <based on docs / API names, what you thought would happen>
- **Actual**: <what happened — error, missing API, confusing behavior>
- **Resolution**: <how you got past it, or "gave up and pivoted">
- **Category**: DOC-MISSING | DOC-WRONG | API-DISCOVERABILITY | API-ERGONOMICS | API-GAP | DESIGN-VS-API-MISMATCH
- **Severity**: blocker | major | minor | papercut

## Entry 2
...
```

**Log liberally.** Surfaces of interest unique to this archetype:

- Discovering that ManifoldKit *does* image generation at all (it markets itself as a chat framework)
- `MLXDiffusionBackend` discoverability — is it findable from the top-level README?
- The first-run download UX: does MK give you primitives for "model needed → download → ready," or do you have to invent them?
- How image generation events are surfaced — is there a streaming/progress signal you can hang a waiting-state UI off, or just a single async result?
- Persistence of image history — does the SwiftData/persistence layer assume "messages" and stretch awkwardly for "image generations," or is it shape-agnostic?
- Voice input: is `ManifoldVoice` accessible without dragging chat assumptions in? What `NS*UsageDescription` keys does the docs tell you to add?
- The umbrella `import ManifoldKit` — does it cover image gen and voice, or do you need specialised imports?
- Design-vs-API mismatches: where the brief describes a UX moment that the public API doesn't naturally support

## What we're trying to learn

This is the third archetype in a DX walkthrough series. Archetypes 1 (chat-cli) and 2 (swiftui-chat) covered the chat happy path. This one tests whether ManifoldKit is *only* a chat framework or whether it lives up to its "local-first AI" framing for non-chat apps that exercise its image-gen + voice modules. It also tests the **designer-to-app** path: can a developer take a real design handoff and ship it on top of MK, or does the framework's chat-shaped surface force the design to bend?

Phase 4 will repeat this exercise on a physical iPhone to get the on-device truth. Phase 3 keeps the variables low (mac, Metal-available, no signing dance) so the friction signal is about MK's public API, not about iOS deployment plumbing.

**Be honest.** If MK is clearly a chat framework that bolted on image gen, say so. If the public surface composes cleanly for non-chat apps, say so. If the design brief asks for things MK has no opinion on, call those out specifically.

## Reporting back

When done (or when time/attempts are exhausted), respond with:
- Whether the app works (yes / no / partially) — call out specifically: did first-run work? did voice work? did generation work? does history persist?
- Path to your run directory
- The 3 highest-severity friction entries, verbatim
- One-line overall verdict on MK as a foundation for non-chat AI apps
