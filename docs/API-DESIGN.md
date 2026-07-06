# API Design — standing policy

> Written for both humans and coding agents. If a PR adds a public symbol, overload, or
> knob, it must be justifiable against this page — not against what compiled cleanly.
> Grounded in `docs/plans/api-review-2026-07.md` (Part A root causes, Phase 0, decision
> queue). This is the consolidation artifact for those decisions — read the plan for the
> evidence, read this page to decide.

## 1. Identity: toolkit-first (decided 2026-07-06)

The engine/contract/ports layer — `ManifoldContract`, `ManifoldInference`, `ManifoldRuntime`,
the backend families — **is the product.** `ChatView` and `quickStart` are the flagship
*consumer* of that toolkit, not a second product with equal claim on defaults.

Consequence: when a default is ambiguous, it follows toolkit values — explicit registrars
over implicit ones, local-first over cloud-first, dependency injection over convention.
`LLM(from:)`'s cloud-by-default posture is the counter-example this identity corrects
(tracked in the plan's 2.5); `quickStart(backends:)`'s explicit registrar list is the
pattern to match going forward.

Why: five real local consumer apps were surveyed (plan Part B.2) — every hand-assembly app
constructs `InferenceService` and registrars explicitly; `LLM` has zero adopters among them.
The toolkit shape is what people actually build with.

## 2. Layer-ownership map

Each tier owns a distinct class of knob. **A knob exists at exactly one layer.** Before
adding a public parameter, field, or config struct, find which layer already owns that
concern and extend it there — don't re-declare it one layer up.

| Tier | Owns | Does NOT own |
|---|---|---|
| Backend contract (`GenerationConfig`, `InferenceBackend.swift`) | Sampling parameters (temperature, topP, penalties, samplers) and per-request orchestration hints (tools, thinking budget, JSON mode) | Scheduling, turn semantics, presentation |
| Engine (`InferenceService`, `GenerationQueue`) | Scheduling, routing, model lifecycle, queueing policy | Sampling values, turn/session semantics |
| Runtime (`ConversationRuntime`, `TurnInput`) | Turn semantics: send / regenerate / edit / cancel / branch, context assembly | Sampler knobs — it consumes `GenerationConfig`, it does not re-declare it |
| UI (`ChatViewModel`, `ChatView`) | Presentation policy only: what's shown, when, in what shape | Sampling, scheduling, persistence shape |
| Umbrella (`ManifoldKit`, `quickStart`) | Composition defaults — which backends/stores wire together out of the box | Any knob not already owned by a lower tier |

**Counter-example (the reason this rule exists):** `TurnConfig`'s sampler defaults
(`temperature: Float = 0.7`, `topP: Float = 0.9` —
`ConversationRuntime+TurnInput.swift:33-34`) are byte-for-byte identical to
`GenerationConfig`'s (`InferenceBackend.swift:409-410`). The runtime tier re-declared a
sampling default the contract tier already owns, and nobody noticed because no doc said
sampling was contract-tier property. Don't repeat this: if you're about to add a sampler
field to anything above `GenerationConfig`, that's the tripwire — thread the existing type
through instead.

## 3. Visibility policy

New declarations default to `package`. A PR must claim `public` explicitly in its body if
it is claiming the declaration as API — visibility is a design decision, not whatever the
compiler accepted.

**Caveat — `package` never crosses a package boundary.** Anything a companion package
(`manifold-mlx`, `manifold-llama`, `manifold-fuzz`, `manifold-tools`) or a consumer app
conforms to, calls, or constructs must stay `public`, full stop. This includes types with
zero in-repo conformers: the opt-in protocols in
`Sources/ManifoldContract/BackendOptInProtocols.swift` (`ImageGenerationBackend`,
`VideoGenerationBackend`, `TokenProvider`, `SessionToolSource`, `CancellableModelLoading`,
`MultimodalProjectorConfigurable`) look unused from a grep of `Sources/` — their real
conformers are `LlamaBackend`/MLX backends in the companion repos plus app-side conformers
(plan Part B.2). "Zero in-repo conformers" is never sufficient evidence to demote a
protocol; grep the companion checkouts and the local consumer apps first.

## 4. Pre-1.0 evolution policy

Breaking is cheap and encouraged, on purpose, through scheduled `feat!:` waves. Pre-1.0:
**delete, don't deprecate.** Deprecation is a post-1.0 tool for a package that has made a
stability promise; this one hasn't yet, and running a post-1.0 process pre-1.0 is what
fossilized the three 15-19 param `enqueue` builders and their shadow typealiases
(`InferenceService.swift:547,598,645`).

Every removal ships a migration note in the same PR. No exceptions — a breaking wave
without a migration note is how three of the five surveyed local apps ended up broken
against `main` after the P7 shim retirement (plan Part B.2); the note is what lets a
consumer fix forward in one pass instead of archaeology.

## 5. Namespace posture

**The SwiftPM products are the API. Module placement is internal topology.** Which
`Sources/` directory a type's file lives in is not a contract with consumers — only the
product graph (`Package.swift` targets/products) and the `@_exported import` chains that
compose them are. The chained re-exports are a feature, not an accident to be undone.

This makes physical relocation a non-blocker where it would otherwise gate a decision:
`ToolTypes.swift`/`BackendCapabilities.swift` live in `ManifoldHardware` for P1c
dependency-layering reasons, not because they're Hardware-concept types — but moving them
into `ManifoldContract` would invert the dependency graph into a cycle (`ManifoldContract`
already depends on `ManifoldHardware`). Under this posture that's fine: fix the doc
comments that describe them as native to their importing module, and stop treating
placement as something worth a breaking move.

## 6. Identifier conventions

- **`UUID`** = local registration identity — an object minted by *this* app instance.
  `ModelInfo.id`, session IDs, message IDs.
- **`String`** = catalog/repo identity — an identifier owned by an external catalog or
  repo, not by this app. `DownloadableModel.id`, `CuratedModel.id`, `ImageModelInfo.id`
  (all HuggingFace repo IDs or equivalent).
- **`BackendName`** (`Sources/ManifoldContract/BackendName.swift`) for backend identity at
  any new seam — it replaced a closed `enum` specifically so companion packages can add
  backend identities without a core release. Use it, don't reach for a bare `String` at a
  new backend-identity seam.

This is a documented convention, not a wrapper type. No `ModelID`-style wrapper — the
plan's decision queue considered and rejected one; reviewers enforce the convention at new
seams instead of the type system enforcing it universally.

## 7. Semver-exempt products

`ManifoldTestSupport`, `ManifoldContractTestSupport`, `ManifoldBackendTestKit` **may break
in any minor release, migration-noted.** This is not "internal use only" — `idlewick` (a
surveyed local app) imports `ManifoldTestSupport` directly, and both companion packages
consume `ManifoldTestSupport`/`ManifoldBackendTestKit`. They get the same delete-and-note
treatment as everything else pre-1.0; they just don't get a deprecation cycle or an
api-digester gate slowing that down.

## 8. Review-loop standing question

Every non-trivial PR's reviewer brief (the `/ship` skeptical-review step) carries this
question verbatim:

> Does this diff add a public symbol, overload, or knob — and does that knob already exist
> at another layer?

If the answer is yes, the fix is to thread the existing type through, not to add a
parallel one. Cite §2 of this doc in the review comment.
