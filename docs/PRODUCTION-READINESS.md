# Production readiness by capability

**Audience:** consumer, contributor
**Status:** living

Normative — states what is true today, dated 2026-07-25.

This page is the single source of truth for ManifoldKit's maturity signal.
Every published SwiftPM product — every `.library` and every executable in
[`Package.swift`](../Package.swift) — is assigned to exactly one of four
tiers below. Coverage is **audit-enforced (exhaustive + non-overlapping) for
every `.library` product**; the 3 executables are assigned by the same page
but are not independently machine-checked — see
[Derivation & governance](#derivation--governance) for the exact scope. It
replaces the scattered `Experimental¹` footnotes that used to be the only
signal (still threaded through [`AGENTS.md`](../AGENTS.md),
[`README.md`](../README.md), and [`docs/API-DESIGN.md`](API-DESIGN.md) §§ 7–7b) —
those now point back here instead of carrying independent judgment calls.

**What this page is not:** a roadmap. It states what tier a product sits in
*today*. Plans to graduate, retire, or restructure a product live in
[`docs/plans/`](plans) and are linked from a tier's notes when one exists —
this page never states an intention, only a current fact.

**How it's kept honest:** `ProductionReadinessTierAuditTest`
(`Tests/ManifoldCoreTests/ProductionReadinessTierAuditTest.swift`) parses
`Package.swift`'s `.library` product list and this file's `TIER-MANIFEST`
blocks (the HTML-comment-delimited bullet lists directly under each tier
heading — the machine-checked canonical list; the prose tables below them
restate the same names with rationale for human readers) and fails CI if a
library product is missing from every tier or listed in more than one. See
[Derivation & governance](#derivation--governance) at the bottom for the
demonstrated-red evidence and update procedure.

## The four tiers

1. **Core guarantees** — inference contract, conversation runtime,
   persistence abstractions, model lifecycle. Full release-gated
   verification (cold-start gates, doc-snippet compile gate, demo-app build
   gate, the per-PR and nightly API-digester baseline); a stability promise
   that becomes contractual at 1.0 ([`docs/RELEASE-1.0.md`](RELEASE-1.0.md)).
2. **Supported first-party integrations** — backends and first-party
   surfaces receiving the same full release-gated verification as Core, but
   scoped to one integration (a backend family, a UI accessory, a companion
   entry point) rather than the shared kernel.
3. **Experimental** — available, no stable compatibility promise; may break
   in any minor release, always with a migration note. This is the existing
   `¹` semantics from `AGENTS.md`/`API-DESIGN.md` § 7b, plus the four
   developer-tooling products `API-DESIGN.md` § 7 exempts from semver for a
   different reason (see [Tier 3](#tier-3--experimental) below).
4. **Labs** — prototypes that may change or be removed *without* a migration
   note. See [Tier 4](#tier-4--labs) — this tier is currently empty, and the
   page says why rather than force-fitting a product into it.

A product's tier describes the **compatibility promise an adopter can rely
on**, not its code quality or how well-tested it is internally — an
Experimental product can be extensively unit-tested and still carry no
stability promise, because "no real adopter has been built against it yet"
(§ 7b's bar) is a fact about the ecosystem, not the code.

## Tier 1 — Core guarantees

<!-- TIER-MANIFEST:core-guarantees -->
- `ManifoldKit`
- `ManifoldContract`
- `ManifoldInference`
- `ManifoldRuntime`
- `ManifoldPersistenceSwiftData`
- `ManifoldModelCatalog`
- `ManifoldHardware`
- `ManifoldNetworking`
- `ManifoldSecrets`
- `ManifoldUI`
<!-- /TIER-MANIFEST -->

| Product | Role | Why Core |
|---|---|---|
| `ManifoldKit` | Umbrella re-export (`ManifoldInference` + `ManifoldRuntime` + `ManifoldPersistenceSwiftData` + the backend families + `ManifoldUI`). | The canonical one-import consumer entry point; carries the aggregate stability promise of everything it re-exports at Core or Supported tier. Experimental products, including `ManifoldAgentInstructions`, require an explicit import. |
| `ManifoldContract` | Backend protocols (`InferenceBackend`, `EmbeddingBackend`), value/stream types (`GenerationConfig`, `GenerationEvent`, `Message`) — the inference contract every backend compiles against. | Literally "the inference contract" named in the tier definition. |
| `ManifoldInference` | Inference orchestration engine: `InferenceService`, `GenerationQueue`, `ModelRegistry`, tool subsystem, `PromptAssembler`, `ContextWindowManager`. | The engine the contract and runtime both depend on; no persistence ports, backend-agnostic. |
| `ManifoldRuntime` | Persistence ports (`MessageStore`, `SessionStore`, `EndpointStore`, …), `ConversationRuntime` — the single send/regenerate/edit/cancel/branch turn loop (Principle 8). | Literally "the conversation runtime" named in the tier definition. |
| `ManifoldPersistenceSwiftData` | SwiftData schema, `@Model` types, container factory, `ManifoldBootstrap`. | Literally "persistence abstractions" — plus the schema-migration promise in `docs/RELEASE-1.0.md` § 2. |
| `ManifoldModelCatalog` | Model discovery/catalog/benchmark: `ModelInfo`, `ModelManifest`, `ModelCatalog`, `ModelStorageService`, `ModelBenchmarkRunner`. | Literally "model lifecycle" named in the tier definition. |
| `ManifoldHardware` | Device-capability probing, GGUF parsing, load-plan logic; also the physical home of the tool-calling value types and `BackendCapabilities` (re-exported through `ManifoldContract`). | Zero-dependency leaf the Contract kernel and model lifecycle are built on — a break here breaks Core transitively. |
| `ManifoldNetworking` | `NetworkActivity` observability funnel, `PrivateIPClassifier`. | Zero-dependency leaf underpinning the cloud/runtime stack. |
| `ManifoldSecrets` | `KeychainService`, `SecureEnclaveKeyManager`, `SecureBytes`. | Zero-dependency leaf underpinning credential storage across persistence and cloud integrations. |
| `ManifoldUI` | SwiftUI chat-runtime views/view models (`ChatView`, `ChatViewModel`) — "chat-only consumer stops here." | Not literally named in the tier-1 description, but carries the same full-gate bar: cold-start gates, the doc-snippet compile gate, and the release-time demo-app build gate all exercise it directly, and Principle 8's one-turn-loop guarantee is only complete once its UI half (`ChatViewModel`) is included. Extending the tier-1 definition to cover it, rather than stretching "backend integration" to fit, is the more honest read — flagged for confirmation in [Open questions](#open-questions) since it's this page's one definitional extension. |

## Tier 2 — Supported first-party integrations

<!-- TIER-MANIFEST:supported-integrations -->
- `ManifoldFoundation`
- `ManifoldOllama`
- `ManifoldCloudSaaS`
- `ManifoldCloudCore`
- `ManifoldUIModelManagement`
- `ManifoldHuggingFace`
- `ManifoldVoice`
- `ManifoldFuzz`
- `ManifoldServerKit`
<!-- /TIER-MANIFEST -->

| Product | Role | Why Supported |
|---|---|---|
| `ManifoldFoundation` | Apple Foundation Models bridge (iOS 26 / macOS 26+, OS-availability-gated, no trait). | Backend family; covered by `ManifoldBackendsTests` and the release-time demo-app gate. |
| `ManifoldOllama` | Ollama (self-hosted/LAN) backend family. | Backend family; covered by `ManifoldBackendsTests`, the Ollama E2E suite, and the demo-app gate. |
| `ManifoldCloudSaaS` | Claude / OpenAI Chat Completions / OpenAI Responses / LM Studio / custom-OpenAI-compatible backend family. | Backend family; covered by `ManifoldBackendsTests` and the demo-app gate. |
| `ManifoldCloudCore` | Shared SSE / TLS-pinning / DNS-rebind / URLSession infra behind both cloud families, plus `DefaultWebSearchRuntime`. Always linked. | The substrate both cloud backend families are built on; same gating bar even though it is not itself a named backend. |
| `ManifoldUIModelManagement` | Model browser/download/storage UI + cloud API endpoint editors. | Linked and exercised by the Advanced example app (release-time demo-app gate); real production surface, not experimental. |
| `ManifoldHuggingFace` | Hub search/browse/background downloads. Compiles unconditionally. | Feeds the model-management UI and the `quickStart` seed path; demo-app-gated. |
| `ManifoldVoice` | Speech I/O adapters, voice composer accessory. | Explicitly confirmed stable-tier in `API-DESIGN.md` § 7b: "a shipping first-party app pins and imports it, verified 2026-07-13" — the one product whose Tier 2 status is externally verified by the same adopter bar that keeps its siblings in Tier 3. |
| `ManifoldFuzz` | Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic. | Not on `API-DESIGN.md` § 7's five-product semver-exemption roster, even though it looks like adjacent developer tooling — that roster is a curated, named list, not a blanket rule for anything test/fuzz-shaped. Its `Package.swift` product comment explains why it was published as a real `.library` in the first place: `manifold-mlx`'s `fuzz-mlx` driver needs to `import ManifoldFuzz` cross-package (a load-bearing dependency, not a test-target-only import), and doing so "re-widens the api-digester gate's product surface" — i.e. it is tracked by the same public-surface baseline as every other non-exempt product, the same gating `ManifoldFoundation`/`ManifoldOllama`/`ManifoldCloudSaaS` get. |
| `ManifoldServerKit` (module `ManifoldServer`) | Embeddable OpenAI-compatible server library — `ManifoldServer.serve(configuration:backendProvider:)`. | A real public seam shipped in #2242, not test/dev tooling; absent from § 7's exemption list. **Caveat:** its api-digester coverage is structurally broken by a SwiftPM tooling limitation (traits don't reach the scratch-checkout build the digester dumps), not a scoping choice — see [Open questions](#open-questions). |

**Executables in this tier:** `ManifoldServer` (the `Server`-trait-gated
OpenAI-compatible HTTP server CLI — pairs with `ManifoldServerKit` above) and
`fuzz-chat` (the CLI driver for `ManifoldFuzz` campaigns, run via
`scripts/fuzz.sh`).

## Tier 3 — Experimental

Two distinct reasons land a product in this tier — both cash out to the same
promise (no stable compatibility guarantee, migration-noted on break), so
they share the tier number, but the "why" differs enough that this page
keeps them under **separate sub-labels rather than one "Experimental"
heading** — `API-DESIGN.md` § 7 is explicit that its four developer-tooling
products are "not internal use only" and have real external consumers, so
filing them under a plain "Experimental" label would contradict the section
that already owns that distinction. See sub-tiers 3a and 3b below.

### 3a. Zero-adopter experimental

`API-DESIGN.md` § 7b roster, declared 2026-07-13: a product graduates only
when a shipping app or companion pins it **and** imports it from non-test
code — verified by grep, not documentation or intent. Each carries a
graduate-or-delete decision point at 1.0 + 2 minors or its named milestone.

<!-- TIER-MANIFEST:experimental-zero-adopter -->
- `ManifoldMCP`
- `ManifoldMCPHost`
- `ManifoldAppIntents`
- `ManifoldAgentInstructions`
- `ManifoldAnyLanguageModel`
- `ManifoldTelemetryOTLP`
- `ManifoldAppEval`
<!-- /TIER-MANIFEST -->

| Product | Role | Reason |
|---|---|---|
| `ManifoldMCP` | Model Context Protocol client surface, descriptors, transports, OAuth, tool bridge. | Zero-adopter — "the best-documented module of the set" per § 7b, still experimental because no consumer app has been built and tested against it. |
| `ManifoldMCPHost` | Runtime-backed MCP server boundary exposing sessions/messages/RAG/send-message as MCP tools. | Zero-adopter; depends on the still-experimental `ManifoldMCP`. |
| `ManifoldAppIntents` | AppIntent ↔ `ToolDefinition` bridge. | Zero-adopter. |
| `ManifoldAgentInstructions` | `AGENTS.md` ambient-instruction filesystem discovery (macOS-only), extracted from the retired `ManifoldSkills` (#2434). | Zero-adopter by the external-consumer bar (no shipping app or companion pins it yet) — but not inert: `ManifoldKit`'s `ConversationRuntimeOptions.addAgentInstructions(currentDirectory:stoppingAt:)` gives it a real in-repo caller and an integration test exercises the full discover → merge → `.systemPreamble` path. Requires explicit `import ManifoldAgentInstructions`; it is not re-exported by the Tier-1 `ManifoldKit` umbrella. |
| `ManifoldAnyLanguageModel` | AnyLanguageModel provider bridge (Gemini, xAI, Groq, Mistral, OpenRouter). | Zero-adopter **and** § 7 dependency-coupled: its surface can only ever be as stable as the external, pre-1.0 `AnyLanguageModel` package it wraps. |
| `ManifoldTelemetryOTLP` | OTLP/HTTP trace exporter. | Zero-adopter. |
| `ManifoldAppEval` | Golden-scenario eval harness for apps built on ManifoldKit (estate#1). | Zero-adopter. |

### 3b. Semver-exempt developer tooling

`API-DESIGN.md` § 7, unchanged by 1.0 per `docs/RELEASE-1.0.md` §
"Semver-exempt and Experimental products": real external consumers exist
(companion packages, `manifold-eval`, the `manifold-tools` CLI) — these are
**not** zero-adopter, and § 7 is explicit that "not internal use only" is
the point. They land here because they are developer tooling, not
app-facing capability, and linking one means accepting the same looser
compatibility promise as 3a, for a different reason.

<!-- TIER-MANIFEST:experimental-semver-exempt-tooling -->
- `ManifoldTestSupport`
- `ManifoldPersistenceTestSupport`
- `ManifoldBackendTestKit`
- `ManifoldTools`
<!-- /TIER-MANIFEST -->

| Product | Role | Reason |
|---|---|---|
| `ManifoldTestSupport` | Shared mocks/fakes (`MockInferenceBackend`, `CharTokenizer`). | Semver-exempt tooling; real consumers: a surveyed first-party app (test-target import), `manifold-mlx`, `manifold-llama`. |
| `ManifoldPersistenceTestSupport` | Persistence-dependent test mocks (`GlassBoxDemoRAG`, `InMemoryPersistenceHarness`, `makeInMemoryContainer()`). | Semver-exempt tooling; split from `ManifoldTestSupport` in the 4.4 arch-plan wave. |
| `ManifoldBackendTestKit` | Backend contract-check machinery, published for companion conformance suites. | Semver-exempt tooling; real consumers: `manifold-mlx`, `manifold-llama`. Links XCTest. |
| `ManifoldTools` | End-to-end tool-call evaluation/conformance harness and BFCL scoring library. | Semver-exempt tooling; real consumers: the in-repo `manifold-tools` CLI and `manifold-eval`. |

**Executables in Tier 3 (3b):** `manifold-tools` (the CLI for
`ManifoldTools`, which is itself semver-exempt tooling above).

## Tier 4 — Labs

<!-- TIER-MANIFEST:labs -->
<!-- /TIER-MANIFEST -->

Empty today, deliberately — this is a factual statement, not a placeholder.
Part 0 Principle 9 requires "a migration note for every retired API… no
exceptions," repo-wide, so nothing currently shipped forgoes even the
Experimental tier's migration-note guarantee. A future prototype that
explicitly opts out of that guarantee (e.g. a throwaway spike product tagged
`Labs` from day one) would land here; none exists as of this writing.

## Open questions

Two placements in this page are judgment calls this audit doesn't fully
settle — flagged rather than silently resolved:

1. **`ManifoldServerKit`'s Tier 2 placement is not fully machine-verified.**
   Its public seam (`ServerBackendProvider`, `ManifoldServer.serve`) is
   absent from `scripts/api-surface-baseline.sh`'s `DEFAULT_MODULES` for a
   documented SwiftPM tooling limitation (`--traits` never reaches the
   scratch-checkout build the digester dumps from, verified three ways
   2026-07-16) — not a scoping choice. It is treated as Tier 2 on the
   strength of its stated intent and non-membership in any exemption list,
   but that placement will keep resting on documentation rather than a gate
   until the tooling limitation is fixed or the module is restructured so
   its seam compiles unconditionally.
2. **Tier 2's stated criterion isn't met by every Tier 2 member.** The tier
   is defined above as receiving "the same full release-gated verification
   as Core," but two of its members don't, today: `ManifoldServerKit` has no
   api-digester coverage at all (see item 2 above), and `ManifoldFuzz` is
   exercised by neither the cold-start gates nor the release-time demo-app
   build gate — nothing in the gate suite links or imports it the way the
   demo app links `ManifoldUIModelManagement`/`ManifoldHuggingFace`/`ManifoldVoice`.
   The property `ManifoldFuzz`'s row cites (tracked in the public-surface
   baseline, not on the § 7 exemption roster) is real, but it doesn't
   discriminate Tier 2 from Tier 3b — every Tier 3b product is tracked in
   that same baseline too (§ 7 says so explicitly). So in practice, the
   operative test this page actually applies for these two products is
   **roster membership and absence from an exemption list**, not gate
   coverage — the tier's own stated bar. This is a gap in what the tier
   promises versus what's verified, not a reason to move either product;
   recorded here rather than silently glossed over.

## Derivation & governance

- **Ground truth:** `Package.swift`'s `products:` array (30 `.library`
  products + 3 executables as of this writing) and `docs/API-DESIGN.md` §§ 7
  and 7b, which already carry the authoritative Experimental/semver-exempt
  rosters this page assembles into the issue-#2337 four-tier shape.
- **Enforcement:** `ProductionReadinessTierAuditTest` fails CI when a
  `.library` product in `Package.swift` is missing from every
  `TIER-MANIFEST` block above, or present in more than one. It does not
  (yet) validate executables or catch a stale name lingering in a tier after
  a product is renamed — see the test file's doc comment for the exact
  scope.
- **Updating this page:** when a product is added, removed, or renamed in
  `Package.swift`, update the matching `TIER-MANIFEST` block (and its prose
  table row) in the same PR. The audit fails loudly if you forget the
  `TIER-MANIFEST` half.
- **Cross-references:** `AGENTS.md`'s `Experimental¹` footnote points here.
  `README.md`'s "Dev-tool products" paragraph points here. `docs/API-DESIGN.md`
  §§ 7 and 7b point here for where their rosters land in the tier picture.
  `docs/RELEASE-1.0.md` § "Semver-exempt and Experimental products" — the
  document [issue #2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211)
  ruled on — points here for the complete tier picture, not just the freeze
  exemptions; [issue #2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211)
  itself carries a comment linking this page for the same reason.
