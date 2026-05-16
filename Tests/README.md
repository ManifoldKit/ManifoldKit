# ManifoldKit Tests

This directory contains the test suites that gate every PR to ManifoldKit. CI runs these on macOS arm64; locally you run them via `scripts/test.sh`.

## Top-level layout

| Suite | Scope | Notes |
|---|---|---|
| `ManifoldCoreTests` | Core models & utilities (no backends, no UI) | Trait-independent. |
| `ManifoldInferenceTests` | `InferenceBackend` plumbing, queues, errors, streaming | Trait-independent. |
| `ManifoldInferenceSwiftTestingTests` | Swift Testing tests for inference. | Runs in a separate process from XCTest (#681). |
| `ManifoldRuntimeTests` | `ConversationRuntime`, session services, ports | Uses in-memory `MessageStore` conformers; no SwiftData. |
| `ManifoldPersistenceSwiftDataTests` | Real SwiftData stack, schemas, migrations | Integration tier: hits SwiftData. |
| `ManifoldBackendsTests` | Per-backend behaviour, capability contracts | Trait-gated; many tests skip without the relevant trait. |
| `ManifoldBackendsTests/Conformance/` | Per-backend conformance suites against the strengthened contract harness | New in T1.1. |
| `ManifoldMCPTests` | MCP protocol, transports, OAuth, sanitizers | `#if MCP`-gated. |
| `ManifoldTestSupportTests` | Sanity tests for `Sources/ManifoldTestSupport/` mocks/fakes | Lightweight. |
| `ManifoldUITests` | SwiftUI view models, view-tree contracts via ViewInspector | `@MainActor`-isolated. |
| `ManifoldUIModelManagementTests` | Model browser/download UI | Depends on `ManifoldUIModelManagement`. |
| `ManifoldVoiceTests` | Voice composer + STT/TTS adapters | Skips without microphone. |
| `ManifoldAppIntentsTests` | App Intent → tool dispatch | iOS 26 / macOS 26 only. |
| `ManifoldServerTests` | ManifoldServer SSE bridge | `#if Server`-gated. |
| `ManifoldE2ETests` | Real-model end-to-end on Llama / MLX / Foundation / Cloud | Hardware required. |
| `ManifoldMLXIntegrationTests` | Real MLX model inference requiring Metal shaders | Xcode-only — `swift test` cannot link the metallib. |
| `APIFreezeTests` | Public-API surface freeze | Compilation IS the assertion (T1.5). |

## Trait conventions

ManifoldKit's test targets are conditionally linked on Swift package traits:

| Trait | Default? | Gates |
|---|---|---|
| `MLX` | yes | MLX backend, mlx-swift-lm dependency |
| `Llama` | yes | LlamaBackend, llama.swift dependency |
| `HuggingFace` | yes | HF model browser |
| `Ollama` | no | Ollama backend, requires `localhost:11434` |
| `CloudSaaS` | no | OpenAI/Claude/Responses backends |
| `MCP` | no | MCP client + transports |
| `MCPBuiltinCatalog` | no | Bundled MCP server descriptors |
| `Tools` | no | `manifold-tools` CLI body |
| `Server` | no | ManifoldServer |
| `Operational` | (planned, T4) | Nightly soak/migration/throughput |

The default-traits build is what CI's per-PR matrix runs against. Use `--disable-default-traits` locally to drop MLX/Llama/HuggingFace (faster, sim-friendly).

**When to disable default traits locally:** any iteration that doesn't exercise a hardware backend — `ManifoldRuntimeTests`, `ManifoldPersistenceSwiftDataTests`, `ManifoldUITests`, `ManifoldInferenceTests`, `ManifoldMCPTests`, `ManifoldServerTests`. Skipping MLX avoids an mlx-swift source checkout and a Metal shader compilation pass on every rebuild — the dominant cost in a default-traits cold build.

**When to keep defaults on:** changes under `Sources/ManifoldMLX/` or `Sources/ManifoldLlama/`, the matching `ManifoldBackendsTests` MLX/Llama suites, and `ManifoldE2ETests`. Those tests `XCTSkip` without the trait — the run looks green but exercises nothing.

## Running a single suite

```bash
# Fastest — single suite, default traits, no remote refresh:
scripts/test.sh --filter ManifoldBackendsTests --disable-default-traits --skip-update

# Whole pre-push (mirrors CI's two-call shape):
scripts/test.sh --filter ManifoldCoreTests --filter ManifoldRuntimeTests \
  --filter ManifoldPersistenceSwiftDataTests --filter ManifoldUITests \
  --filter ManifoldUIModelManagementTests --filter ManifoldMCPTests \
  --filter ManifoldBackendsTests --filter ManifoldInferenceTests \
  --filter ManifoldTestSupportTests --filter ManifoldAppIntentsTests \
  --filter ManifoldServerTests \
  --disable-default-traits --skip-update

scripts/test.sh --filter ManifoldInferenceSwiftTestingTests \
  --disable-default-traits --skip-update
```

`--skip-update` is safe unless you touched `Package.swift` (drop it then to refresh resolution).

## Test classification

| Kind | Where it lives | What it does |
|---|---|---|
| **Unit** | `Manifold<Module>Tests/` | One module under test, mocks at the module boundary. No SwiftData, no Metal, no real network. |
| **Integration** | `Manifold<Module>Tests/` (named `…IntegrationTests` or `…E2ETests`) | Two or more modules wired together. May hit SwiftData via `InMemoryPersistenceHarness`. |
| **End-to-end** | `ManifoldE2ETests/` | Full chain through a real backend. Requires Metal / a model file / a network endpoint. |

If your test hits SwiftData, it's an integration test — name and place it accordingly. Per CLAUDE.md: "Do not mock the persistence layer. Use in-memory SwiftData stores."

## Adding a new backend

1. Implement `InferenceBackend` (and any opt-in protocols) in `Sources/ManifoldBackends/<YourBackend>.swift`.
2. Add a conformance test class under `Tests/ManifoldBackendsTests/Conformance/<YourBackend>ConformanceTests.swift`. Subclass `XCTestCase` and opt into the relevant contract mixins:

   ```swift
   final class YourBackendConformanceTests: XCTestCase,
                                            BackendContractMixin,
                                            GrammarFailClosedContractMixin {
       let contractBackendName = "YourBackend"

       func makeContractBackend() -> YourBackend {
           YourBackend()
       }

       override func setUp() {
           super.setUp()
           BackendContractChecks.resetCapabilityClaims()
       }

       func test_universalInvariants_allPass() {
           assertUniversalBackendContract()
       }

       @MainActor
       func test_grammarFailClosed_throwsUnsupportedGrammar() async throws {
           try await assertGrammarFailClosedContract()
       }

       // …other per-capability assertions…

       func test_metaContract() {
           BackendContractChecks.assertCapabilityMetaContract(
               backendName: "YourBackend",
               capabilities: YourBackend().capabilities
           )
       }
   }
   ```

3. If the backend adopts an opt-in protocol, add the matching mixin (`ConversationHistoryReceiverContractMixin`, `StructuredHistoryReceiverContractMixin`, etc.) and a concrete `test_…` method that calls its assertion helper. Protocol-extension methods are not XCTest-discoverable on their own.
4. Every `true` capability flag your backend declares must have at least one assertion family that records a claim against it (or call `claimWithoutBehaviouralAssertion(...)` as a temporary bootstrap — file the follow-up issue).
5. Every `false` flag with a fail-closed contract (today: `supportsGrammarConstrainedSampling`) must run its fail-closed family.
6. Run `scripts/test.sh --filter ManifoldBackendsTests` and verify the meta-contract test passes.

The full assertion shape is documented in `Tests/ManifoldBackendsTests/BackendContractTests.swift`.

## Sabotage evidence

New behaviour assertions ship with an inline `// Sabotage-evidence:` block recording **all three**:

```swift
// Sabotage-evidence:
//   M1: comment out Sources/.../X.swift:N → test fails with <message>
//   M2: change OOD nonce literal → test fails with <message>
//   M3: flip gating capability flag to false → test correctly skipped
```

This proves the assertion (a) exercises a real production code path, (b) is value-sensitive, and (c) gates correctly on the relevant capability. Strip the M1/M2 mutations before commit; the evidence text stays.

## Special cases

- **MLX integration**: `scripts/test-mlx-integration.sh` — Xcode-only, metallib required. See #986.
- **Llama isolation**: `scripts/test-llama-isolated.sh` — runs LlamaBackend tests in a separate process to avoid global-init contamination.
- **MCP E2E**: `RUN_MCP_E2E=1 swift test --traits MCP --filter ManifoldMCPE2ESmokeTests` — gated env var + trait. The `everything-server` smoke has hung in past runs; filter to the streamable subset.
- **Ollama**: requires `localhost:11434` and `--traits Ollama`.
- **Operational tier** (planned): nightly trait `Operational` for soak/migration/throughput/quality baseline.

### Cold-start conformance gates

Cold-start gates scaffold a fresh SwiftPM consumer in a tmpdir, depend on this repo via `.package(path:, name: "ManifoldKit", ...)`, and exercise the public surface from outside — catching breakage that in-tree tests miss because the in-tree compiler sees internals the fresh consumer cannot. Each gate's CI job in `.github/workflows/ci.yml` lists its own script path under `paths:` so edits to the gate re-trigger the gate (see `feedback_ci_path_filter_self_validation`).

| Tier | Script | Surface |
|---|---|---|
| 1 | `scripts/cold-start-conformance.sh` | Low-level public API: `InferenceService`, backends, generation events. |
| 2 | `scripts/cold-start-tier2-bootstrap.sh` | `ManifoldBootstrap` + `ChatViewModel` orchestration. |
| 3 | `scripts/cold-start-tier3-chatview.sh` | `ManifoldUI` `ChatView` composition with `@State` view models, `.environment(_:)` injection, and the `apiConfiguration: () -> View` view-builder closure. |

## Who runs what

| Audience | Suite |
|---|---|
| Per-PR CI | All default-trait suites (the two-call shape above) |
| Per-PR CI (matrix) | Per-trait builds for MCP, Ollama, CloudSaaS |
| Nightly | `ManifoldE2ETests`, MLX integration, `Operational` (planned T4) |
| Pre-push (local) | The two-call shape |
| Hardware-specific | `ManifoldE2ETests/LlamaThinkingE2ETests` etc. — install fixtures via `~/Library/Caches/ManifoldKit/test-models/manifest.json` |

## Pre-push checklist

Before every push: run the two-call shape against `--disable-default-traits`. CI runs on macOS (10× billing). One failed push wastes ~25 billed minutes — test locally first.
