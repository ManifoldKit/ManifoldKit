# Production readiness by capability

**Audience:** consumer, contributor
**Status:** living

Normative compatibility-tier assignment — dated 2026-08-16. Current release
qualification is separately recorded in
[`docs/RELEASE-1.0.md`'s release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger).

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
   persistence abstractions, model lifecycle. This is the Core compatibility
   commitment, including the full release-gated verification bar; whether the
   required current-release evidence is presently satisfied is recorded in
   the [release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger).
   Its stability promise becomes contractual at 1.0
   ([`docs/RELEASE-1.0.md`](RELEASE-1.0.md)).
2. **Supported first-party integrations** — backends and first-party
   surfaces carrying the same release-gated compatibility bar as Core, scoped to one
   integration (a backend family, a UI accessory, a companion entry point)
   rather than the shared kernel. Their current-release qualification is also
   in the [release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger),
   not inferred from this tier label.
3. **Experimental** — available, no stable compatibility promise; may break
   in any minor release, always with a migration note. This is the existing
   `¹` semantics from `AGENTS.md`/`API-DESIGN.md` § 7b, plus the four
   developer-tooling products `API-DESIGN.md` § 7 exempts from semver for a
   different reason (see [Tier 3](#tier-3--experimental) below).
4. **Labs** — prototypes that may change or be removed *without* a migration
   note. See [Tier 4](#tier-4--labs) — this tier is currently empty, and the
   page says why rather than force-fitting a product into it.

A product's tier describes the **compatibility commitment** assigned to its
public surface, not its code quality or how well-tested it is internally — an
Experimental product can be extensively unit-tested and still carry no
stability promise, because "no real adopter has been built against it yet"
(§ 7b's bar) is a fact about the ecosystem, not the code.

**Qualification is a second signal.** An unresolved Tier 1/2 health row
withholds the affected release promise; it does not silently rewrite the
product's compatibility tier. This distinction prevents a stale or missing CI
run from making the tier tables falsely read as a current release approval.

## Demonstration signal (R1/R2/R3)

A tier states the compatibility promise a product carries; it says nothing
about whether a reader can actually see the product working today. That
second question is answered by a separate, complementary instrument:
[`docs/DEMO-COVERAGE.md`](DEMO-COVERAGE.md) and its live source,
[`scripts/demo-coverage-manifest.tsv`](../scripts/demo-coverage-manifest.tsv)
(the demonstration program tracked by
[issue #2453](https://github.com/ManifoldKit/ManifoldKit/issues/2453)). That
manifest scores every ManifoldKit **capability** — a finer grain than the
`.library`/`.executable` products this page tiers, since one product can
carry several capabilities and one capability can span several products —
against three requirements, computed by `scripts/demo-coverage.sh`:

- **R1 — demonstrated by a runnable vehicle.** An example app, a focused
  example, a script, a scenario, or an external (companion-repo) vehicle
  exists for the capability.
- **R2 — documented with a link that can't drift.** The row's doc reference
  names a file that exists on disk right now.
- **R3 — a declared execution route, not just a labelled one.** The
  capability fires on a named, *executed* CI lane (`per-pr`, `release-gate`,
  `live-e2e`, `weekly`, or `external` — never `manual` or `none`) whose own
  invocation actually runs the vehicle (`exec_kind: live` or `scripted`,
  never a `compile`-only build). Where the lane names a test file or
  workflow, R3 is further **method-bound**: the manifest records the exact
  test method(s) that exercise the capability, not a suite-level assumption.
  R3 is a declared route, not a freshness signal — it does not assert the
  lane ran recently or is currently green; last-run/staleness evidence is a
  later milestone (M5) of the same issue.

This page does not restate the manifest's table here — a copied snapshot
would drift the moment a row changed, and nothing on this page would catch
that drift the way `DocClaimsAuditTest` catches a dead symbol or a broken
link. Run `scripts/demo-coverage.sh` for the current scoreboard, or read the
manifest directly.

**The two signals are orthogonal, deliberately.** A Tier 1 Core capability
can have an unmet R3 today (`turn-loop-actions`: regenerate/edit/branch have
no exercising test anywhere, only send/clear do) while a Tier 3 Experimental
capability can have a fully met R1/R2/R3 (`mcp-client`, scored live via
`RUN_MCP_E2E=1 swift test --filter ManifoldMCPE2ESmokeTests`). A product's
tier is not a proxy for its demonstration status, and this page does not
attempt to derive one from the other — the tables below answer the
compatibility-promise question; the manifest answers the demonstration
question.

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
| `ManifoldUI` | SwiftUI chat-runtime views/view models (`ChatView`, `ChatViewModel`) — "chat-only consumer stops here." | Not literally named in the tier-1 description, but belongs to the same compatibility commitment: Principle 8's one-turn-loop guarantee is only complete once its UI half (`ChatViewModel`) is included. Actual release-gate health, including the endpoint-configuration path, is in the [release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger); tier membership is not a claim that every gate is currently green. |

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
- `ManifoldAppEval`
<!-- /TIER-MANIFEST -->

| Product | Role | Why Supported |
|---|---|---|
| `ManifoldFoundation` | Apple Foundation Models bridge (iOS 26 / macOS 26+, OS-availability-gated, no trait). | Backend family; covered by `ManifoldBackendsTests` and the release-time demo-app gate. |
| `ManifoldOllama` | Ollama (self-hosted/LAN) backend family. | Backend family. Its tool-continuation terminal-state qualification is currently blocked in the [release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger) (#2376), so this tier assignment is not current release approval for that path. |
| `ManifoldCloudSaaS` | Claude / OpenAI Chat Completions / OpenAI Responses / LM Studio / custom-OpenAI-compatible backend family. | Backend family; covered by `ManifoldBackendsTests` and the demo-app gate. |
| `ManifoldCloudCore` | Shared SSE / TLS-pinning / DNS-rebind / URLSession infra behind both cloud families, plus `DefaultWebSearchRuntime`. Always linked. | The substrate both cloud backend families are built on; same gating bar even though it is not itself a named backend. |
| `ManifoldUIModelManagement` | Model browser/download/storage UI + cloud API endpoint editors. | Linked and exercised by the Advanced example app (release-time demo-app gate); real production surface, not experimental. |
| `ManifoldHuggingFace` | Hub search/browse/background downloads. Compiles unconditionally. | Feeds the model-management UI and the `quickStart` seed path; demo-app-gated. |
| `ManifoldVoice` | Speech I/O adapters, voice composer accessory. | Explicitly confirmed stable-tier in `API-DESIGN.md` § 7b: "a shipping first-party app pins and imports it, verified 2026-07-13" — the one product whose Tier 2 status is externally verified by the same adopter bar that keeps its siblings in Tier 3. |
| `ManifoldFuzz` | Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic. | Not on `API-DESIGN.md` § 7's five-product semver-exemption roster, even though it looks like adjacent developer tooling — that roster is a curated, named list, not a blanket rule for anything test/fuzz-shaped. Its `Package.swift` product comment explains why it was published as a real `.library` in the first place: `manifold-mlx`'s `fuzz-mlx` driver needs to `import ManifoldFuzz` cross-package (a load-bearing dependency, not a test-target-only import), and doing so "re-widens the api-digester gate's product surface" — i.e. it is tracked by the same public-surface baseline as every other non-exempt product, the same gating `ManifoldFoundation`/`ManifoldOllama`/`ManifoldCloudSaaS` get. |
| `ManifoldServerKit` (module `ManifoldServer`) | Embeddable OpenAI-compatible server library — `ManifoldServer.serve(configuration:backendProvider:)`. | A real public seam shipped in #2242, not test/dev tooling; absent from § 7's exemption list. **Caveat:** its api-digester coverage is structurally broken by a SwiftPM tooling limitation (traits don't reach the scratch-checkout build the digester dumps), not a scoping choice — see [Qualification gaps](#qualification-gaps). |
| `ManifoldAppEval` | Golden-scenario eval harness for apps built on ManifoldKit (estate#1): scenario schema, turn-loop runner, `CheckpointScorer`, report generation. | Graduated from Tier 3a on the first-real-adopter rule (`AGENTS.md`; `API-DESIGN.md` § 7b) — the same adopter bar that keeps `ManifoldVoice` at this tier. Two real adopters: fireside declares the product for Sources+Tests (`Packages/FiresideEval/Package.swift`) and drives `GoldenTaskRunner` via `FiresideGoldenTaskAdapter`/`FiresideGraphCheckpointScorer`, exercised per-PR by fireside's `macos-ci.yml`; idlewick is a second adopter (its `iwk` CLI target imports the product from non-test code, with `AppEvalReportBuilderTests` CI-executed). See the `app-eval` row in `scripts/demo-coverage-manifest.tsv` for the full evidence chain. **Caveat:** it has no in-repo demo-app vehicle yet (`vehicle: none` pending an example-app wire-up), and its core-main release evidence remains a pending registry-derived canary in the [release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger). |

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
- `ManifoldTelemetryOTLP`
<!-- /TIER-MANIFEST -->

| Product | Role | Reason |
|---|---|---|
| `ManifoldMCP` | Model Context Protocol client surface, descriptors, transports, OAuth, tool bridge. | Zero-adopter — "the best-documented module of the set" per § 7b, still experimental because no consumer app has been built and tested against it. |
| `ManifoldMCPHost` | Runtime-backed MCP server boundary exposing sessions/messages/RAG/send-message as MCP tools. | Zero-adopter; depends on the still-experimental `ManifoldMCP`. |
| `ManifoldAppIntents` | AppIntent ↔ `ToolDefinition` bridge. | Zero-adopter. |
| `ManifoldAgentInstructions` | `AGENTS.md` ambient-instruction filesystem discovery (macOS-only), extracted from the retired `ManifoldSkills` (#2434). | Zero-adopter by the external-consumer bar (no shipping app or companion pins it yet) — but not inert: `ManifoldKit`'s `ConversationRuntimeOptions.addAgentInstructions(currentDirectory:stoppingAt:)` gives it a real in-repo caller and an integration test exercises the full discover → merge → `.systemPreamble` path. Requires explicit `import ManifoldAgentInstructions`; it is not re-exported by the Tier-1 `ManifoldKit` umbrella. |
| `ManifoldTelemetryOTLP` | OTLP/HTTP trace exporter. | Zero-adopter. |

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

## Qualification gaps

Tier membership is deliberately not used to hide evidence gaps. The
current release-blocking set and its evidence-to-clear live in the
[release-health ledger](RELEASE-1.0.md#release-health--qualification-ledger).
Two product-scoped questions remain here because they concern compatibility
classification as well as a particular release's health. They do not reorder
the immediate remediation lanes, but their affected promises remain withheld
in the ledger:

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
2. **Several Tier 2 products need more direct release evidence.**
   `ManifoldServerKit` has no api-digester coverage (item 1), `ManifoldFuzz`
   is not linked by the cold-start or release-time demo-app gates, and
   `ManifoldAppEval` has no in-repo demo-app vehicle (`vehicle: none` in
   `scripts/demo-coverage-manifest.tsv`). Their tier placement rests on their
   stated compatibility scope and non-exempt roster status; the release-health
   ledger is where missing evidence becomes a release decision rather than a
   silent contradiction in the tier definition.

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
  itself carries a comment linking this page for the same reason. This page,
  in turn, points to [`docs/DEMO-COVERAGE.md`](DEMO-COVERAGE.md) for the
  complementary per-capability demonstration signal — see
  [Demonstration signal](#demonstration-signal-r1r2r3) above; that page does
  not carry tier assignments of its own.
