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
`LLM(from:)`'s cloud-by-default posture was the counter-example this identity corrects
(plan item 2.5 — **corrected 2026-07**: `LLM.init`'s `backends:` is now a required
parameter with no default); `quickStart(backends:)`'s explicit registrar list is the
pattern to match going forward.

Why: five real local consumer apps were surveyed (plan Part B.2) — every hand-assembly app
constructs `InferenceService` and registrars explicitly; `LLM` has zero adopters among them.
The toolkit shape is what people actually build with.

Decay hook: any PR that adds new public surface to the *secondary* identity (the
ChatView/quickStart framework tier) must cite this ranking in its PR body — the previous
ranking (SCOPE_DECISION.md, 2026-04) rotted silently because nothing forced the citation.

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

The contract-tier refactor decided 2026-07-06 (plan 2.3 Option C) **shipped in #2169**
(v0.69.0 train): the lossy non-persisted `GenerationConfig` fields moved into
`GenerationRuntimeHints`; `GenerationConfig` is now flat and honestly Codable. The
remaining `GenerationConfig.init` parameters are all contract-tier-owned sampler and
payload knobs — there is no further init-slimming debt.

**Per-turn context contribution is two seams, owned by two tiers** (decided 2026-07-13,
v1-rationalisation plan B.1, adversarial-review-confirmed): prompt-slot contribution
(`PromptContextProvider` / `ProviderBudget` / `PromptSlot`, budget-planned assembly) is
assembly-tier property in `ManifoldInference`; message-level history contribution
(`HistoryProvider` / `HistoryContribution`) is turn-semantics property in
`ManifoldRuntime`. A history insertion is not expressible as a prompt slot — do not
merge these, and do not add a third contribution seam; extend whichever tier owns the
concern. Store post-write hooks (`MessageStorePostWriteHook` /
`SessionStorePostWriteHook`) are a third, persistence-tier seam: they fire on any
store write, not just generation turns, and stay outside the generation-lifecycle
`HookRegistry`.

**Lifecycle signals are two seams, owned by two tiers** (decided 2026-07-14,
v1-rationalisation plan B.4): a generation turn's lifecycle (queued → connecting →
loading/streaming → stalled/retrying → done/failed) is **stream-scoped** — owned by
`GenerationStream.phase` in `ManifoldContract`, one instance per in-flight request.
A model load's lifecycle (idle → loading → loaded/failed) is **coordinator-scoped** —
owned by `ModelLoadStatus` via `ModelLoadCoordinator.statusUpdates()` in
`ManifoldInference`, one multi-observer fan-out per `InferenceService`. These are the
canonical signals for their respective lifecycles going forward; see the
LifecycleSignals DocC article
(`Sources/ManifoldInference/ManifoldInference.docc/Articles/LifecycleSignals.md`)
for consumption examples.

Two older signals overlap these and are **legacy, slated for demotion only after the
origin app migrates onto the canonical pair** (plan B.0/B.4 — this decision documents
the losers, it does not cut them yet): `BackendActivityPhase` (the hand-maintained
state machine the origin app's input bar renders directly today) and
`ModelLoadReadinessState` (an older idle/loading/ready polling enum still used
internally by `InferenceService.waitUntilModelReady`). Point new work at
`GenerationStream.phase` / `ModelLoadStatus` — do not add new consumers of either
legacy signal. This resolves the #2128 `.phase` item ("emitted, nothing renders")
with a documented consumer path instead of a cut: the writer side was already live
across `GenerationQueue` and the cloud/Ollama SSE paths (see the LifecycleSignals
article for file:line evidence) — the actual gap was the absence of an in-repo reader and of
this ownership documentation, not a dead write.

## 3. Visibility policy

New declarations default to `package`. A PR must claim `public` explicitly in its body if
it is claiming the declaration as API — visibility is a design decision, not whatever the
compiler accepted.

**Caveat — `package` never crosses a package boundary.** Anything a companion package
(`manifold-mlx`, `manifold-llama`; plus `manifold-fuzz` and `manifold-tools` — extraction
decided 2026-07-06, pending) or a consumer app conforms to, calls, or constructs must stay
`public`, full stop. Two grep traps when screening a demotion candidate:

- **Zero in-repo conformers does not mean dead.** The opt-in protocols in
  `Sources/ManifoldContract/BackendOptInProtocols.swift` (`CancellableModelLoading`,
  `MultimodalProjectorConfigurable`) have no conformers in `Sources/` — their only real
  conformers are `LlamaBackend`/MLX backends in the companion repos. The same holds for
  the scattered opt-in seams `ImageGenerationBackend` (`ManifoldContract`),
  `VideoGenerationBackend` (`ManifoldInference`), `TokenProvider` (`ManifoldCloudCore`),
  which have app-side conformers (plan Part B.2).
- **In-repo counts must be verified per-protocol, not assumed.** `SessionToolSource`
  (`Sources/ManifoldRuntime/Services/SessionToolSource.swift`) looks like the same shape
  but has 5+ in-repo production conformers (`SkillToolSource`, `WebSearchToolSource`,
  `ImageGenerationToolSource`, `VideoGenerationToolSource`, `HandoffToolSource`) — plus
  app-side ones.

Before any demotion: grep the companion checkouts and the local consumer apps, per-protocol.

## 4. Pre-1.0 evolution policy

Breaking is cheap and encouraged, on purpose, through scheduled `feat!:` waves. Pre-1.0:
**delete, don't deprecate.** Deprecation is a post-1.0 tool for a package that has made a
stability promise; this one hasn't yet, and running a post-1.0 process pre-1.0 is what
fossilized the three deprecated 15-19 param `enqueue` builders
(`InferenceService.swift:547,598,645`) and the since-removed `ChatSessionRecord`/`ChatMessageRecord`
shadow typealiases (formerly in `ConversationRecords.swift`; deleted in #2167).

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

Five products **may break in any minor release, always migration-noted.** This is
not "internal use only" — they have real external consumers and published surfaces. Breaking
changes receive the same delete-and-note treatment as everything else pre-1.0, without
deprecation cycles or api-digester gates slowing removal. The exemption is **documentation-only**:
these products stay in `scripts/api-surface-baseline.sh`'s `DEFAULT_MODULES`, in ci.yml's and
nightly-slow-tests.yml's digester `--targets` list, and in `PublicSurfaceBaselineTests
.expectedModules`, same as every other published product — the gates keep running and keep
catching *accidental* breaks. What the exemption removes is the ceremony around an
*intentional* one: no deprecation cycle, no migration-window shim — just a
`.github/api-breakage-allowlist.txt` entry (same mechanism already used for false-positive
"removed" reports) and a changelog note, same as any other pre-1.0 delete-don't-deprecate
change (Part 0, principle 9).

Four of the five are exempt because of their **purpose** (developer tooling), not their
reachability — an app CAN link them from any target (the surveyed consumers below all link
from test targets), it just accepts the looser stability promise when it does:

- **`ManifoldTestSupport`** — shared mocks and testing utilities. Published as a `.library`
  product. Real consumers: a surveyed first-party app (test-target import — re-verified
  2026-07 during the 4.4 split; an earlier survey note claiming app-code import was wrong);
  `manifold-mlx` and `manifold-llama` (companion packages, for backend test fixtures).
- **`ManifoldPersistenceTestSupport`** — the persistence-dependent test mocks split out of
  `ManifoldTestSupport` (arch-plan 4.4, wave2 P2, #2158): `GlassBoxDemoRAG`,
  `InMemoryPersistenceHarness`, `makeInMemoryContainer()`. Published as a `.library` product.
  Consumer survey at split time (2026-07): the surveyed first-party app, `manifold-mlx`, and `manifold-llama`
  all import `ManifoldTestSupport` from test targets only, and none reference any of the
  three moved symbols — no external consumer needed a migration draft for this split.
- **`ManifoldBackendTestKit`** — backend contract-check machinery and conformance harness.
  Published as a `.library` product. Real consumers: `manifold-mlx` and `manifold-llama`
  (published conformance suites). Links XCTest, so callable only from test targets.
- **`ManifoldTools`** — end-to-end tool-call evaluation harness and scoring library.
  Published as a `.library` product with executable `manifold-tools` CLI. Real consumers:
  `manifold-tools` CLI (linked by the core package); `manifold-eval` (published `ConformanceRecord`
  / `ASTMatcher` / `MatrixRenderer` reuse, BFCL runner). Exposes ~70 public types
  for conformance scoring and scenario description.

(`ManifoldContractTestSupport` is deliberately absent from this list: it is a target, not a
published product — external pins cannot reach it, so it needs no exemption.)

The fifth is exempt for a different reason — a leaked *dependency* type, not developer tooling:

- **`ManifoldAnyLanguageModel`** — the AnyLanguageModel provider bridge (Gemini, xAI, Groq,
  Mistral, OpenRouter). `AnyLanguageModelDescriptor.model: any LanguageModel`
  (`Sources/ManifoldAnyLanguageModel/AnyLanguageModelCapabilities.swift`) names a protocol
  owned by the external [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)
  package, pinned pre-1.0 (`from: "0.8.0"`, Package.swift). The module's entire purpose is
  bridging that dependency, so its public surface can only ever be as stable as the upstream
  package — a wrapper around `any LanguageModel` would insulate nothing (it breaks whenever
  the protocol does) while adding a layer every consumer must learn. Its stability tracks
  AnyLanguageModel's, not ManifoldKit's release cadence (#2209).

## 7b. Experimental products (declared 2026-07-13, v1-rationalisation plan Phase C)

Products with **zero real adopters** do not enter the 1.0 stability promise. They may
break in any minor, always migration-noted — pre-1.0 rules (§4) continue to apply to
them after core 1.0. Roster: `ManifoldMCP`, `ManifoldMCPHost`, `ManifoldSkills`,
`ManifoldAppIntents`, `ManifoldAnyLanguageModel` (additionally dependency-coupled per
§7 above), `ManifoldTelemetryOTLP`, `ManifoldAppEval`.

- **Adopter** = a shipping app or companion package that pins the product AND imports
  it from non-test code, verified by grep — not documentation, not examples, not
  intent. (This bar is what keeps `ManifoldVoice` stable-tier: a shipping first-party
  app pins and imports it, verified 2026-07-13. And it is why `ManifoldMCP` is
  experimental despite being the best-documented module of the set — decided
  2026-07-13: MCP graduates only when a consumer app has been built and tested
  against it.)
- **Not a parking lot:** each experimental product carries a graduate-or-delete
  decision point — at 1.0 + 2 minors or its named milestone, whichever comes first,
  it either has an adopter (graduates into the frozen contract, and its internals get
  the §3 demotion screen as part of graduation) or it gets a wire-or-delete
  adjudication like any other inert surface (principle 10).
- The api-surface baseline still tracks experimental products (drift stays visible);
  the 1.0 freeze discipline applies only to stable-tier products.

## 8. Review-loop standing question

Every non-trivial PR's reviewer brief (the `/ship` skeptical-review step) carries this
question verbatim:

> does this diff add a public symbol or knob, and does that knob already exist at another
> layer?

If the answer is yes, the fix is to thread the existing type through, not to add a
parallel one. Cite §2 of this doc in the review comment.
