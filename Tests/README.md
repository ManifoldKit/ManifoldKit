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
| `ManifoldBackendsTests` | Per-backend behaviour, capability contracts | Cloud (Ollama / OpenAI / Claude / LM Studio), Foundation, and mock backend suites. The MLX and llama.cpp suites moved to the companion repos (manifold-mlx / manifold-llama) in v0.48. |
| `ManifoldBackendsTests/Conformance/` | Per-backend conformance suites against the strengthened contract harness | New in T1.1. |
| `ManifoldFuzzTests` | Fuzz harness engine tests | Compiles unconditionally since v0.48 (the `Fuzz` trait is retired). |
| `ManifoldMCPTests` | MCP protocol, transports, OAuth, sanitizers | Compiles unconditionally (MCP trait retired in v0.48). |
| `ManifoldTestSupportTests` | Sanity tests for `Sources/ManifoldTestSupport/` mocks/fakes | Lightweight. |
| `ManifoldUITests` | SwiftUI view models, view-tree contracts via ViewInspector | `@MainActor`-isolated. |
| `ManifoldUIModelManagementTests` | Model browser/download UI | Depends on `ManifoldUIModelManagement`. |
| `ManifoldVoiceTests` | Voice composer + STT/TTS adapters | Skips without microphone. |
| `ManifoldAppIntentsTests` | App Intent → tool dispatch | iOS 26 / macOS 26 only. |
| `ManifoldServerTests` | ManifoldServer SSE bridge | `#if Server`-gated. |
| `ManifoldE2ETests` | Real-model end-to-end on Ollama / Foundation / Cloud | Requires a live Ollama server or iOS 26 / macOS 26. The Llama/MLX real-model E2E suites moved to the companion repos. |
| `APIFreezeTests` | Public-API surface freeze | Compilation IS the assertion (T1.5). |

## Trait conventions

Since v0.48 there are **no default traits** — plain `swift test` builds and runs the full core surface (`--disable-default-traits` is obsolete). The surviving opt-in traits:

| Trait | Default? | Gates |
|---|---|---|
| `Server` | no | ManifoldServer (Hummingbird) and `ManifoldServerTests` |
| `Macros` | no | `@ToolSchema` macro plugin (swift-syntax) |
| `Operational` | (planned, T4) | Nightly soak/migration/throughput |

The retired local-backend traits (`MLX`, `Llama`, `HuggingFace`, `Fuzz`, `FoundationOnly`) died with the v0.48 companion-package split — the MLX and llama.cpp backend test suites (including the Xcode-hosted MLX integration tests) now live in [manifold-mlx](https://github.com/roryford/manifold-mlx) and [manifold-llama](https://github.com/roryford/manifold-llama). Family-backend test conventions are documented in those repos.

## Running a single suite

```bash
# Fastest — single suite, no remote refresh:
scripts/test.sh --filter ManifoldBackendsTests --skip-update

# Whole pre-push (mirrors CI's two-call shape):
scripts/test.sh --profile local
```

`--skip-update` is safe unless you touched `Package.swift` (drop it then to refresh resolution).

## Test classification

| Kind | Where it lives | What it does |
|---|---|---|
| **Unit** | `Manifold<Module>Tests/` | One module under test, mocks at the module boundary. No SwiftData, no Metal, no real network. |
| **Integration** | `Manifold<Module>Tests/` (named `…IntegrationTests` or `…E2ETests`) | Two or more modules wired together. May hit SwiftData via `InMemoryPersistenceHarness`. |
| **End-to-end** | `ManifoldE2ETests/` | Full chain through a real backend. Requires Metal / a model file / a network endpoint. |

If your test hits SwiftData, it's an integration test — name and place it accordingly. Per CLAUDE.md: "Do not mock the persistence layer. Use in-memory SwiftData stores."

## Per-protocol contract mixins

`Sources/ManifoldTestSupport/Contracts/` contains opt-in XCTestCase mixin protocols for the core ManifoldKit protocols. Each file is named `<ProtocolName>Contract.swift`.

| Contract protocol | Validates |
|---|---|
| `InferenceBackendContract` | `InferenceBackend` — load/unload cycle, generation, cancellation, capabilities |
| `EmbeddingBackendContract` | `EmbeddingBackend` — load/unload, `embed()` shape, error on unloaded call |
| `MessageStoreContract` | `MessageStore` — insert/fetch/update/delete, session isolation, timestamp ordering, pagination |
| `SessionStoreContract` | `SessionStore` — insert/fetch/update/delete, most-recently-updated ordering, `deleteAll`, pagination |
| `EndpointStoreContract` | `EndpointStore` — insert/fetch/update/delete, most-recently-created ordering |
| `SamplerPresetStoreContract` | `SamplerPresetStore` — insert/fetch/delete, most-recently-created ordering |
| `BenchmarkCacheContract` | `BenchmarkCache` — upsert/fetchAll, replacement semantics, multi-key isolation |

`ManifoldMCPTests/Contracts/MCPToolSourceContractTests.swift` covers `MCPToolSource` behavioral invariants (not a mixin — `ManifoldMCP` is not a dependency of `ManifoldTestSupport`).

`ManifoldBackendsTests/Contracts/URLSessionProviderContractTests.swift` covers `URLSessionProvider` security and configuration invariants (not a mixin — `ManifoldCloudCore` is not a dependency of `ManifoldTestSupport`).

### Adopting a contract mixin

Contract methods are named `assert<Protocol>_<scenario>` rather than `test_*` because XCTest does not discover protocol-extension methods. The concrete subclass calls each helper from a `test_`-prefixed method:

```swift
// In ManifoldTestSupportTests (or the target that owns the implementation):
@MainActor
final class MyMessageStoreContractTests: XCTestCase, MessageStoreContract {
    func makeMessageStore() -> any MessageStore {
        MyMessageStore()
    }

    func test_insertThenFetch() async throws {
        try await assertMessageStore_insertThenFetchReturnsRecord()
    }
}
```

Reference adopters live alongside their target:

| Adopter file | Target | Contract |
|---|---|---|
| `ManifoldTestSupportTests/MockInferenceBackendContractTests.swift` | `ManifoldTestSupportTests` | `InferenceBackendContract` via `MockInferenceBackend` |
| `ManifoldRuntimeTests/MessageStoreContractAdopterTests.swift` | `ManifoldRuntimeTests` | `MessageStoreContract` via in-memory double |
| `ManifoldRuntimeTests/SessionStoreContractAdopterTests.swift` | `ManifoldRuntimeTests` | `SessionStoreContract` via in-memory double |
| `ManifoldRuntimeTests/EndpointStoreContractAdopterTests.swift` | `ManifoldRuntimeTests` | `EndpointStoreContract` via in-memory double |
| `ManifoldRuntimeTests/SamplerPresetStoreContractAdopterTests.swift` | `ManifoldRuntimeTests` | `SamplerPresetStoreContract` via in-memory double |
| `ManifoldRuntimeTests/BenchmarkCacheContractAdopterTests.swift` | `ManifoldRuntimeTests` | `BenchmarkCacheContract` via in-memory double |

## Adding a new backend

> Adding a *heavy local* backend family (new ML runtime)? That belongs in a companion package — follow [manifold-llama](https://github.com/roryford/manifold-llama) / [manifold-mlx](https://github.com/roryford/manifold-mlx) as the templates; they consume the same `ManifoldBackendTestKit` contract harness described below. The steps here cover backends that live in this repo (cloud families, Foundation-class bridges).

1. Implement `InferenceBackend` (and any opt-in protocols) in the relevant family target (e.g. a new `Sources/Manifold<Family>/` target, registered through the `ManifoldBackendsUmbrella` glue).
2. Add a conformance test class under `Tests/ManifoldBackendsTests/Conformance/<YourBackend>ConformanceTests.swift`. Subclass `XCTestCase` and opt into the relevant contract mixins:

   ```swift
   final class YourBackendConformanceTests: XCTestCase,
                                            BackendContractMixin,
                                            GrammarFailClosedContractMixin {
       let contractBackendName = "YourBackend"

       func makeContractBackend() -> YourBackend {
           YourBackend()
       }

       override class func setUp() {
           super.setUp()
           BackendContractChecks.resetCapabilityClaims(forBackend: "YourBackend")
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

The full assertion shape is documented in `Sources/ManifoldBackendTestKit/BackendContractChecks.swift` — the contract checks and mixins ship as the `ManifoldBackendTestKit` product so companion backend packages (manifold-mlx / manifold-llama, #1749) run the same suite via `import ManifoldBackendTestKit` (no `@testable` access). Its DocC catalog documents the adoption walkthrough, the no-`--parallel` claims-registry rule, and the non-vacuity expectation.

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

- **MCP E2E**: `RUN_MCP_E2E=1 swift test --filter ManifoldMCPE2ESmokeTests` — gated by env var (the target compiles unconditionally since the MCP trait was retired in v0.48). The `everything-server` smoke has hung in past runs; filter to the streamable subset.
- **Ollama**: requires `localhost:11434` (backend always compiled since v0.48).
- **Operational tier** (planned): nightly trait `Operational` for soak/migration/throughput/quality baseline.

### Local fixture manifest

The shared model-fixture manifest (`~/Library/Caches/ManifoldKit/test-models/manifest.json` with `MID_THINKING` / `Q8_VARIANT` / `MLX_VLM` slots) moved with the real-model E2E conformance suites to the companion repos — see the manifold-llama and manifold-mlx test docs for the slot definitions, the operational (T4) baselines, and the Xcode-hosted vision runs. The surviving core E2E suites (Ollama / Foundation / Cloud) need only a live Ollama server or iOS 26 / macOS 26 — no manifest.

### Cross-cutting QA practices

Beyond the unit/integration/E2E pyramid below, ManifoldKit ships four cross-cutting QA practices: **DX walkthroughs** ([`scripts/dx-walkthrough/`](../scripts/dx-walkthrough/README.md)), **audit tests** (19 files matching `Tests/*/*AuditTest*.swift`), an **audit sabotage suite** ([`Tests/ManifoldAuditSabotageSuiteTests/`](ManifoldAuditSabotageSuiteTests/AuditSabotageSuiteTests.swift)), and **cold-start conformance gates** (described below). For the discovery doc — what each catches, why it exists, how to run, how to extend — see [`docs/QA-PRACTICES.md`](../docs/QA-PRACTICES.md).

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
| Per-PR CI | All suites (the two-call shape above) |
| Nightly | `ManifoldE2ETests`, `Operational` (planned T4) |
| Pre-push (local) | `scripts/test.sh --profile local` (the two-call shape) |
| Backend-hardware E2E | Companion repos (manifold-mlx / manifold-llama) |

## Pre-push checklist

Before every push: run `scripts/test.sh --profile local`. CI runs on macOS (10× billing). One failed push wastes ~25 billed minutes — test locally first.
