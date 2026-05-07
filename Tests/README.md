# BaseChatKit Tests

This directory contains the test suites that gate every PR to BCK. CI runs these on macOS arm64; locally you run them via `scripts/test.sh`.

## Top-level layout

| Suite | Scope | Notes |
|---|---|---|
| `BaseChatCoreTests` | Core models & utilities (no backends, no UI) | Trait-independent. |
| `BaseChatInferenceTests` | `InferenceBackend` plumbing, queues, errors, streaming | Trait-independent. |
| `BaseChatInferenceSwiftTestingTests` | Swift Testing tests for inference. | Runs in a separate process from XCTest (#681). |
| `BaseChatRuntimeTests` | `ConversationRuntime`, session services, ports | Uses in-memory `MessageStore` conformers; no SwiftData. |
| `BaseChatPersistenceSwiftDataTests` | Real SwiftData stack, schemas, migrations | Integration tier: hits SwiftData. |
| `BaseChatBackendsTests` | Per-backend behaviour, capability contracts | Trait-gated; many tests skip without the relevant trait. |
| `BaseChatBackendsTests/Conformance/` | Per-backend conformance suites against the strengthened contract harness | New in T1.1. |
| `BaseChatMCPTests` | MCP protocol, transports, OAuth, sanitizers | `#if MCP`-gated. |
| `BaseChatTestSupportTests` | Sanity tests for `Sources/BaseChatTestSupport/` mocks/fakes | Lightweight. |
| `BaseChatUITests` | SwiftUI view models, view-tree contracts via ViewInspector | `@MainActor`-isolated. |
| `BaseChatUIModelManagementTests` | Model browser/download UI | Depends on `BaseChatUIModelManagement`. |
| `BaseChatVoiceTests` | Voice composer + STT/TTS adapters | Skips without microphone. |
| `BaseChatAppIntentsTests` | App Intent → tool dispatch | iOS 26 / macOS 26 only. |
| `BaseChatServerTests` | BaseChatServer SSE bridge | `#if Server`-gated. |
| `BaseChatE2ETests` | Real-model end-to-end on Llama / MLX / Foundation / Cloud | Hardware required. |
| `BaseChatMLXIntegrationTests` | Real MLX model inference requiring Metal shaders | Xcode-only — `swift test` cannot link the metallib. |
| `APIFreezeTests` | Public-API surface freeze | Compilation IS the assertion (T1.5). |

## Trait conventions

BCK's test targets are conditionally linked on Swift package traits:

| Trait | Default? | Gates |
|---|---|---|
| `MLX` | yes | MLX backend, mlx-swift-lm dependency |
| `Llama` | yes | LlamaBackend, llama.swift dependency |
| `HuggingFace` | yes | HF model browser |
| `Ollama` | no | Ollama backend, requires `localhost:11434` |
| `CloudSaaS` | no | OpenAI/Claude/Responses backends |
| `MCP` | no | MCP client + transports |
| `MCPBuiltinCatalog` | no | Bundled MCP server descriptors |
| `Tools` | no | `bck-tools` CLI body |
| `Server` | no | BaseChatServer |
| `Operational` | (planned, T4) | Nightly soak/migration/throughput |

The default-traits build is what CI's per-PR matrix runs against. Use `--disable-default-traits` locally to drop MLX/Llama (faster, sim-friendly).

## Running a single suite

```bash
# Fastest — single suite, default traits, no remote refresh:
scripts/test.sh --filter BaseChatBackendsTests --disable-default-traits --skip-update

# Whole pre-push (mirrors CI's two-call shape):
scripts/test.sh --filter BaseChatCoreTests --filter BaseChatRuntimeTests \
  --filter BaseChatPersistenceSwiftDataTests --filter BaseChatUITests \
  --filter BaseChatUIModelManagementTests --filter BaseChatMCPTests \
  --filter BaseChatBackendsTests --filter BaseChatInferenceTests \
  --filter BaseChatTestSupportTests --filter BaseChatAppIntentsTests \
  --filter BaseChatServerTests \
  --disable-default-traits --skip-update

scripts/test.sh --filter BaseChatInferenceSwiftTestingTests \
  --disable-default-traits --skip-update
```

`--skip-update` is safe unless you touched `Package.swift` (drop it then to refresh resolution).

## Test classification

| Kind | Where it lives | What it does |
|---|---|---|
| **Unit** | `BaseChat<Module>Tests/` | One module under test, mocks at the module boundary. No SwiftData, no Metal, no real network. |
| **Integration** | `BaseChat<Module>Tests/` (named `…IntegrationTests` or `…E2ETests`) | Two or more modules wired together. May hit SwiftData via `InMemoryPersistenceHarness`. |
| **End-to-end** | `BaseChatE2ETests/` | Full chain through a real backend. Requires Metal / a model file / a network endpoint. |

If your test hits SwiftData, it's an integration test — name and place it accordingly. Per CLAUDE.md: "Do not mock the persistence layer. Use in-memory SwiftData stores."

## Adding a new backend

1. Implement `InferenceBackend` (and any opt-in protocols) in `Sources/BaseChatBackends/<YourBackend>.swift`.
2. Add a conformance test class under `Tests/BaseChatBackendsTests/Conformance/<YourBackend>ConformanceTests.swift`. Subclass `XCTestCase` and use the strengthened harness:

   ```swift
   override func setUp() {
       super.setUp()
       BackendContractChecks.resetCapabilityClaims()
   }

   func test_universalInvariants_allPass() {
       BackendContractChecks.assertAllInvariants(makingBackend: { YourBackend() })
   }

   func test_grammarFailClosed_throwsUnsupportedGrammar() async throws {
       try await BackendContractChecks.assertGrammarFailClosedContract(
           backendName: "YourBackend",
           makingBackend: { YourBackend() }
       )
   }

   // …other per-capability assertions…

   func test_metaContract() {
       BackendContractChecks.assertCapabilityMetaContract(
           backendName: "YourBackend",
           capabilities: YourBackend().capabilities
       )
   }
   ```

3. Every `true` capability flag your backend declares must have at least one assertion family that records a claim against it (or call `claimWithoutBehaviouralAssertion(...)` as a temporary bootstrap — file the follow-up issue).
4. Every `false` flag with a fail-closed contract (today: `supportsGrammarConstrainedSampling`) must run its fail-closed family.
5. Run `scripts/test.sh --filter BaseChatBackendsTests` and verify the meta-contract test passes.

The full assertion shape is documented in `Tests/BaseChatBackendsTests/BackendContractTests.swift`.

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
- **MCP E2E**: `RUN_MCP_E2E=1 swift test --traits MCP --filter BaseChatMCPE2ESmokeTests` — gated env var + trait. The `everything-server` smoke has hung in past runs; filter to the streamable subset.
- **Ollama**: requires `localhost:11434` and `--traits Ollama`.
- **Operational tier** (planned): nightly trait `Operational` for soak/migration/throughput/quality baseline.

## Who runs what

| Audience | Suite |
|---|---|
| Per-PR CI | All default-trait suites (the two-call shape above) |
| Per-PR CI (matrix) | Per-trait builds for MCP, Ollama, CloudSaaS |
| Nightly | `BaseChatE2ETests`, MLX integration, `Operational` (planned T4) |
| Pre-push (local) | The two-call shape |
| Hardware-specific | `BaseChatE2ETests/LlamaThinkingE2ETests` etc. — install fixtures via `~/Library/Caches/BaseChatKit/test-models/manifest.json` |

## Pre-push checklist

Before every push: run the two-call shape against `--disable-default-traits`. CI runs on macOS (10× billing). One failed push wastes ~25 billed minutes — test locally first.
