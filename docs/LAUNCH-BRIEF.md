# ManifoldKit — Launch Brief

> Launch preparation for distribution after WWDC 2026 — distribution-readiness
> audit, imagery briefs, draft announcement, and post-WWDC sequencing.
> Positioning language is canonical in [POSITIONING.md](POSITIONING.md); the
> audit below reflects the repo at v0.42.0 (pre-1.0).

---

## 1. Distribution-readiness audit

Status legend: ✅ ready · ⚠️ present but weak/incomplete · ❌ missing.

| Item | Status | Note |
|------|--------|------|
| **License** | ✅ | `LICENSE` present — **MIT**. Permissive, correct for an open-source SDK. |
| **README hero / intro** | ⚠️ | Strong content and a `quickStart` snippet up top, but **no hero image or layer-cake diagram** above the fold — the ASCII architecture block is far down the page. The one-liner now leads (this PR), but a hero visual is still missing. |
| **Badges (CI/license/version/platforms)** | ❌ | **Zero badges.** No CI status, license, SPM-compatible, latest-release, or platform badges in the README header. Cheapest credibility win available. |
| **Screenshots** | ⚠️ | `Example/Screenshots/` has exactly two: `demo-macos.png` and `demo-ios.png`, embedded in README §Demo. Adequate but thin — no model-management, RAG citations, thinking-block, or image-gen shots despite all shipping. |
| **Social preview image (GitHub OG, 1280×640)** | ❌ | None present. GitHub falls back to the avatar + repo name when the launch link is shared. High-leverage miss for a Show HN / Mastodon push. |
| **GitHub topics / keywords** | ❌ | **No topics set.** Repo is undiscoverable via `swift`, `llm`, `mlx`, `swiftui`, `on-device`, `foundation-models`, etc. |
| **Repo description / homepage** | ⚠️ | Description is fine but doesn't carry the full-stack one-liner; `homepageUrl` blank (point it at a DocC site or README anchor). |
| **DocC** | ✅ | **12 `.docc` catalogs** across modules with Articles (MCP getting-started, AgentHandoffs, HookSystem, Skills). ⚠️ **No published hosted site or single docs index** — discoverability depends on cloning. Consider a Swift-DocC GitHub Pages deploy. |
| **docs/ index** | ⚠️ | `docs/` is deep but there's **no `docs/README.md` index** tying the set together. |
| **CONTRIBUTING.md** | ✅ | Present, substantial — includes architecture invariants the README links to. |
| **CODE_OF_CONDUCT.md** | ⚠️ | Present but short (~43 lines) — verify it names an enforcement contact; consider full Contributor Covenant. |
| **SECURITY.md** | ✅ | Present, backed by `docs/THREAT_MODEL.md`, `docs/FIPS.md`, fuzz harness. Security-as-product story is real and documented. |
| **CHANGELOG.md** | ✅ | Present, Release-Please-managed, Prisma-style highlights. |
| **Tagged releases** | ✅ | 130+ tags, latest **v0.42.0**. Healthy cadence. ⚠️ All **0.x — pre-1.0**, breaking changes between minors (honest state). |
| **Demo / Example app** | ✅ | `Example/` has `MinimalExample` (canonical Hello World), `Advanced` reference app, `AdvancedUITests`, and its own README. Strong. |
| **Install snippet** | ✅ | Clear SPM `.package(url:from:)` + per-target `.product` snippet, release-please-pinned version. |
| **Threat model / reliability docs** | ✅ | `docs/THREAT_MODEL.md`, `docs/RELIABILITY.md` (source-backed contract) — differentiators most kits lack. |

### Before-launch checklist (prioritized)

**P0 — do before the post goes live (cheap, high-leverage):**
1. **Add GitHub topics** — `swift`, `swiftui`, `llm`, `mlx`, `llama-cpp`, `on-device-ai`, `foundation-models`, `openai`, `anthropic`, `ollama`, `mcp`, `rag`, `chat-ui`, `ios`, `macos`. (2 minutes, pure discoverability.)
2. **Create a 1280×640 social preview** (imagery brief §2) and upload via repo Settings → Social preview.
3. **Add a README badge row** — CI status, MIT license, SPM-compatible, latest release (v0.42.0), platforms (iOS 18+ / macOS 15+), Swift 6.1+.
4. **Add the layer-cake hero image** above the fold (imagery §2.1). (The one-liner intro itself landed in this PR.)
5. **Set `homepageUrl`** (DocC site or docs index).

**P1 — strongly want for launch credibility:**
6. **Capture the screenshot shot-list** (imagery §2.5) — model management, RAG citations, thinking-block, image-gen — so the "already ships" claims are visible, not asserted.
7. **Add a `docs/README.md` index** linking the doc set by use case.
8. **Publish DocC to GitHub Pages** and link it from README + homepageUrl.
9. **Expand `CODE_OF_CONDUCT.md`** to full Contributor Covenant with an enforcement email.

**P2 — nice to have / fast follow:**
10. Prune any stale `.docc` copies under worktree directories; keep them gitignored.
11. Cut a **v1.0** once breaking-change cadence settles (see §4).

---

## 2. Imagery brief

Five visuals plus a screenshot shot-list. Captions are launch-ready (drawn from
the canonical pillars). House style: clean, flat, Apple-adjacent; SF-family
typeface; light + dark variants; restrained accent palette (one cool primary,
one warm accent for the "owned" band).

### 2.1 Hero "layer-cake" diagram

**Purpose:** the single most important visual — proves Pillar 1 (full-stack
altitude) at a glance. This is the README hero and the basis for the social
preview.

**Visual:** Four horizontal bands stacked vertically, each full-width, rounded
corners, like a layer cake viewed from the side. Top to bottom:

- **Band 1 — UI** (top): label `SwiftUI` · chips: `ChatView` · `SessionListView` · `ModelManagementSheet` · `thinking-block UI` · `RAG citations`.
- **Band 2 — Runtime**: label `ConversationRuntime` · chips: `turn loop (send / regenerate / edit / cancel / branch)` · `tool-approval gating` · `metrics + cost`.
- **Band 3 — Persistence**: label `SwiftData` · chips: `MessageStore` · `SessionStore` · `EndpointStore` · `migrations V3→V5`.
- **Band 4 — Backends** (bottom): label `Inference` · chips: `MLX` · `llama.cpp` · `Foundation Models` · `OpenAI` · `Anthropic` · `Ollama` · `AnyLanguageModel bridge`.

**The "owned" treatment:** all four bands are saturated/filled in ManifoldKit's
accent color and bracketed on the **left** by a tall vertical brace labeled
**"ManifoldKit — one import."** On the **right**, three faded ghost-columns each
cover only ONE band, labeled **"UI-only kits stop here"** (aligned to Band 1),
**"engine-only stops here"** (Band 4), **"thin cloud clients stop here"** (a
sliver of Band 4). A small annotation: *"Everyone else owns one band. You wire
the other three yourself."*

**Caption:** *"One import = ChatView + the ConversationRuntime turn loop +
SwiftData persistence + model-management UI + every backend. Competitors hand
you one layer and a wiring diagram."*

### 2.2 "One protocol, every backend" fan diagram

**Purpose:** Pillar 2 (backend portability).

**Visual:** A single rounded node centered-left labeled **`GenerationStream`
(one protocol)**, with a clean fan of lines radiating right to backend nodes,
grouped by family with subtle background grouping bands:

- **On-device:** `MLX` · `llama.cpp (GGUF)`
- **Apple:** `Foundation Models`
- **Cloud:** `OpenAI (Chat + Responses)` · `Anthropic` · `Ollama` · `LAN`
- **Via AnyLanguageModel bridge:** `Gemini` · `xAI` · `Groq` · `Mistral` (drawn as a second-hop fan off a single `AnyLanguageModel` relay node, to show it's complementary, not parallel).

Every edge is the same weight/color — visually asserting "identical features."
Footer chip strip under all nodes: `streaming · tool calling · structured
output · thinking tokens · MCP`.

**Caption:** *"Swap MLX for Claude for a local GGUF by changing one descriptor.
Same streaming, tool-calling, and structured-output surface across all of them —
AnyLanguageModel wrapped as just another backend."*

### 2.3 "vs the field" matrix visual

**Purpose:** make the category claim undeniable.

**Visual:** A filled/empty capability grid. Rows = capabilities; columns =
contenders. Cells: filled accent dot = yes, hollow ring = no, half-dot = partial.

| Capability | ManifoldKit | UI-only kits | Engine-only | Thin cloud clients | Apple Foundation Models |
|---|---|---|---|---|---|
| Drop-in chat UI | ● | ● | ○ | ○ | ○ |
| Turn-loop runtime | ● | ○ | ○ | ○ | ○ |
| SwiftData persistence | ● | ○ | ○ | ○ | ○ |
| Multi-backend (local + cloud) | ● | ○ | ◐ | ○ | ○ |
| On-device + cloud in one API | ● | ○ | ◐ | ○ | ○ |
| Tool calling / structured output | ● | ○ | ◐ | ◐ | ◐ |
| MCP client + server | ● | ○ | ○ | ○ | ○ |
| RAG + citations | ● | ○ | ○ | ○ | ○ |
| Security as product | ● | ○ | ○ | ◐ | n/a |
| Serves iOS 18 / macOS 15 | ● | ● | ● | ● | ○ (OS 26 only) |

Render ManifoldKit's column as a solid filled stripe; the rest mostly hollow.
Footer: *"Full-stack 'competitors' (fullmoon, Enchanted) are forkable apps, not
packages."*

**Caption:** *"UI kits draw bubbles. Engines stream tokens. Cloud clients wrap
one API. Only ManifoldKit fills the whole column — as a package you import, not
an app you fork."*

### 2.4 WWDC-timing visual

**Purpose:** Pillar 3 — turn Apple's keynote into a tailwind, not a threat.

**Visual:** A horizontal timeline/funnel. Left: a box labeled **"WWDC 2026 —
whatever Apple ships next."** An arrow flows right into ManifoldKit's backend
band, where it lands as **one more node labeled "+1 backend"** (not a crater
labeled "rewrite"). Three supporting callout chips below:

- **n-1 reach:** *"serves iOS 18 / macOS 15 that Foundation Models can't touch."*
- **FoundationOnly build:** *"~5 MB lean App-Store build, OR the full stack — same package."*
- **Pre-wired stub traits:** `SystemAIProviderExtension` · `CoreAI` — *"the slots are already cut."*

Contrast device: a faint crossed-out "REWRITE" ghost behind the "+1 backend"
node.

**Caption:** *"When Apple announces a new on-device model, it's one more backend
behind the same `GenerationStream` protocol — not a migration. The stub traits
are already in `Package.swift`."*

### 2.5 Screenshot shot-list

Capture on real devices/simulators, light + dark, with realistic (non-placeholder)
conversation content.

| Shot | Platform / screen | Target size | Why |
|------|------|------|------|
| **GitHub social preview** | composited hero (use §2.1 layer-cake or a macOS chat hero) | **1280×640** (GitHub OG) | shows when the launch link is shared anywhere |
| **macOS chat + sidebar** | `ChatView` + `SessionListView`, mid-stream response | 2560×1600 @2x | the money shot — full product in one frame |
| **iOS chat** | iPhone, streaming conversation | 1179×2556 (iPhone @3x) | mobile credibility |
| **Model management / download** | `ModelManagementSheet`, a download in progress with quantization variants | 2560×1600 | proves "model mgmt UI ships," not just backends |
| **RAG citations** | `CitationsView` with inline citations expanded | 2560×1600 | differentiator most kits lack |
| **Thinking-block UI** | a reasoning model with the collapsible thinking block | 1179×2556 | shows thinking-token support |
| **On-device image-gen** | FLUX/SDXL result in-chat with progress | 2560×1600 | proves "beyond chat" surface |

Each screenshot doubles as a README §Demo addition and an inline asset in the
launch post.

---

## 3. Draft launch gist / announcement

> Title suggestion: **"ManifoldKit: the missing full-stack chat package for
> Swift"** — ~520 words. Edit the intro hook per channel (Show HN vs dev.to vs
> Mastodon).

---

### The gap

Every Swift developer building an LLM chat feature hits the same wall. The UI
kits (Exyte, MessageKit, SwiftyChat) draw beautiful bubbles but know nothing
about models. The engines (LocalLLMClient, AnyLanguageModel, LLM.swift) stream
tokens but hand you no UI, no persistence, no turn loop. The cloud clients
(MacPaw/OpenAI, SwiftAnthropic) wrap one API and stop. Apple's Foundation Models
are free and excellent — and only exist on OS 26, as one capped model.

So you glue four libraries together, write your own SwiftData layer, hand-roll a
streaming turn loop, and rediscover certificate pinning the hard way. JavaScript
developers reach for `assistant-ui` or Vercel's chatbot template. **Swift has
had no equivalent.**

### The one-liner

**ManifoldKit is the only open-source Swift package that bundles UI + runtime +
persistence + multi-backend inference into one drop-in chat product.**

### Four pillars

1. **Full-stack altitude.** One import gives you `ChatView`, the
   `ConversationRuntime` turn loop (send / regenerate / edit / cancel / branch),
   SwiftData persistence, model-management UI, and the backends — not a wiring
   diagram.
2. **Backend portability.** MLX, llama.cpp, Apple Foundation Models, OpenAI
   (Chat + Responses), Anthropic, Ollama, LAN, plus an AnyLanguageModel bridge
   for Gemini / xAI / Groq / Mistral. One `GenerationStream` protocol, identical
   features — streaming, tools, structured output, thinking tokens.
3. **n-1 OS reach, WWDC-ready.** Serves iOS 18 / macOS 15 that Foundation Models
   can't reach, wraps FM as just one backend, and ships either a ~5 MB
   `FoundationOnly` build or the whole stack.
4. **Reliability & security as a product.** TLS pinning, SSRF/DNS guards,
   throwing Keychain, a published threat model, a fuzz harness, 5,700+ tests,
   capability-routed structured output, and tool-approval gating.

### Drop it in

```swift
import SwiftUI
import ManifoldKit

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView(showModelManagement: .constant(false))
                    .environment(result.viewModel)
                    .modelContainer(result.bootstrap.modelContainer)
            } else {
                ProgressView().task { result = try? await ManifoldKit.quickStart() }
            }
        }
    }
}
```

`quickStart()` builds the SwiftData container, registers the compiled-in
backends, and wires a `ChatViewModel` — one call.

### The WWDC hook

WWDC 2026 is days away. Whatever on-device model Apple announces, ManifoldKit
treats it as **one more backend behind the same protocol, not a rewrite** — the
`SystemAIProviderExtension` / `CoreAI` stub traits are already in
`Package.swift`.

### Honest state

ManifoldKit is **v0.42.0, pre-1.0.** Streaming, multi-provider abstraction, tool
calling, structured output, MCP (client + server), thinking tokens, RAG +
citations, metrics + cost, and on-device image generation (FLUX / SDXL) all ship
today. Expect breaking changes between minors until 1.0. RAG reranking
([#1637](https://github.com/roryford/ManifoldKit/issues/1637)) and mid-stream
resume are on the roadmap.

MIT licensed. Issues, PRs, and "does it do X?" questions all welcome.
**→ github.com/roryford/ManifoldKit**

---

### Micro-thread (3 posts, Mastodon / X)

**1/**
Building an LLM chat feature in Swift? You glue a UI kit + an engine + a cloud
client + your own SwiftData layer + a hand-rolled streaming loop. JS devs just
`npm i assistant-ui`. Swift had no equivalent.

So I built ManifoldKit. 🧵

**2/**
One open-source Swift package = `ChatView` + the turn-loop runtime + SwiftData
persistence + every backend. MLX, llama.cpp, Apple Foundation Models, OpenAI,
Anthropic, Ollama — one `GenerationStream` protocol, identical features.
`try await ManifoldKit.quickStart()` and you have a chat app.

**3/**
WWDC 2026 next week? Whatever on-device model Apple ships = one more backend,
not a rewrite (the stub traits are already in Package.swift). Plus it serves iOS
18 / macOS 15 that Foundation Models can't. Pre-1.0, MIT, 5,700+ tests.
→ github.com/roryford/ManifoldKit

---

## 4. Post-WWDC sequencing

**Before posting (land these first):**

1. **Positioning PR** (this one) — README leads with the one-liner, adds the
   "Why ManifoldKit" pillars, the "vs the field" table, and the "what's already
   in the box" checklist; new `POSITIONING.md` + this brief. Follow with the
   badge row, the §2.1 layer-cake hero, and the social-preview asset. (Topics +
   `homepageUrl` are repo-settings, not a PR — do them same-day.)
2. **1.0-readiness framing** — you don't need to *cut* 1.0 before posting, but
   the post claims "pre-1.0, breaking changes between minors," so make that
   honest and bounded: a short stability note and a visible 1.0 milestone with
   the remaining breaking changes listed. Capture the screenshot shot-list
   (§2.5) so "already ships" is shown, not asserted.
3. **[#1637](https://github.com/roryford/ManifoldKit/issues/1637) (RAG rerank)**
   — currently the named gap in the announcement's honest close. Either land it
   before posting (and upgrade RAG from "+citations" to "+rerank") or leave it
   as the explicit roadmap item the draft already cites. Don't post with it
   half-done and unmentioned.
4. **[#1638](https://github.com/roryford/ManifoldKit/issues/1638)
   (AnyLanguageModel bridge → documented provider-breadth path)** — directly
   backs Pillar 2 and the fan diagram's Gemini/xAI/Groq/Mistral nodes. Landing
   it (or at least a documented path) makes the §2.2 visual truthful rather than
   aspirational. Prioritize it just behind the positioning PR.

**Suggested order:** topics + social preview + homepageUrl (settings, day 0) →
positioning PR → #1638 (so the breadth claim is documented) → #1637 (or defer
with explicit roadmap mention) → screenshot shot-list → publish.

**What the WWDC keynote unlocks (draft the day-of follow-up now, fill the blank
after):**

- **If Apple ships a new on-device model / expanded Foundation Models:** post the
  §2.4 timing visual — *"ManifoldKit already wraps it as one backend; here's the
  same `quickStart()` running on it."* Convert `SystemAIProviderExtension` /
  `CoreAI` from stub to real and ship it as a fast-follow PR + a "Day-one WWDC
  support" note.
- **If Apple expands OS availability / APIs:** lean the n-1 message — *"on the new
  OS today via Foundation Models, AND on the two OS versions back that it can't
  reach."*
- **If Apple ships nothing material here:** the post still stands unchanged — the
  WWDC hook is "whatever ships = one more backend," which is true in the null
  case too. No edit needed.

Keep the day-of follow-up to one post that points back at the launch thread.
