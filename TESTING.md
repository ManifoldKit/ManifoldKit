# Testing Guide

This document describes BaseChatKit's testing philosophy, architecture, and patterns. It is aimed at contributors (including those new to Swift) and serves as both a reference and a rationale for how and why tests are structured the way they are.

---

## Table of Contents

- [Testing Pyramid](#testing-pyramid)
- [Test Targets](#test-targets)
- [Feature Coverage Matrix](#feature-coverage-matrix)
- [Async Testing Patterns](#async-testing-patterns)
- [AI-Specific Flow Testing](#ai-specific-flow-testing)
- [Mock Infrastructure](#mock-infrastructure)
- [Writing New Tests](#writing-new-tests)
- [Known Gaps](#known-gaps)

---

## Testing Pyramid

BaseChatKit uses a five-layer testing pyramid. Each layer catches different classes of bugs at different costs:

```
         ╱  XCUITests (Example app)         ╲   Few, slow, high confidence
        ╱   Headless E2E (real components)    ╲  Real wiring, no UI, CI-safe
       ╱    Integration (ViewModel + SwiftData) ╲ Real persistence, mock backends
      ╱     Unit (models, services, protocols)   ╲ Fast, isolated, exhaustive
     ╱      Static (compiler + SwiftUI previews)  ╲ Free, always on
```

**Guiding principle:** push tests as far *down* the pyramid as they can go. A test that can run without a UI should not be an XCUITest. A test that can run without SwiftData should not be an integration test. The lower the layer, the faster and more reliable the test.

### Layer 1 — Static Analysis (Compiler + Previews)

Swift's type system is your first line of defence. Strong typing, `Sendable` checking, and exhaustive `switch` statements catch entire classes of bugs at compile time. SwiftUI `#Preview` blocks verify that views render without crashing and serve as living documentation for consumers.

Previews are *not* asserted today (see [Known Gaps](#known-gaps)).

### Layer 2 — Unit Tests

Isolated tests for individual types: models, services, protocols, error types. These use no persistence, no UI, and no real backends.

**Examples:** `PromptTemplateTests`, `CompressionTests`, `SSEStreamParserTests`, `RetryPolicyTests`

### Layer 3 — Integration Tests

Tests that wire together 2+ real components. The most common pattern is ChatViewModel + MockInferenceBackend + real in-memory SwiftData. These verify that the ViewModel orchestrates persistence, streaming, and state correctly.

**Examples:** `ChatViewModelIntegrationTests`, `ConcurrencyTests`, `CancellationTests`, `StreamingFailureTests`

### Layer 4 — Headless E2E Tests

Tests that use real components wired together — real ViewModels, real SwiftData, real compression pipelines — with only the inference backend mocked (to avoid hardware dependencies). These exercise real pipelines end-to-end without requiring a UI or hardware.

**Examples:** `ContextOverflowE2ETests`, `DownloadValidationE2ETests`, `CloudBackendSSETests`

### Layer 5 — XCUITests (Example App)

UI automation tests that launch the real Example app in a simulator and drive it through user journeys. These are the slowest and most fragile tests, reserved for validating user-visible flows that can't be tested headlessly.

**Examples:** `ChatFlowUITests`, `SessionManagementUITests`, `ModelManagementUITests`

---

## Test Targets

| Target | Layer | Runs in CI | Hardware needed | Framework |
|--------|-------|-----------|-----------------|-----------|
| `BaseChatCoreTests` | Unit, Integration | Yes | None | Mixed (XCTest + Swift Testing) |
| `BaseChatInferenceTests` | Unit, Integration | Yes | None | XCTest |
| `BaseChatInferenceSwiftTestingTests` | Unit | Yes | None | Swift Testing |
| `BaseChatUITests` | Integration | Yes | None | XCTest |
| `BaseChatMCPTests` | Unit, Integration | Yes | None | XCTest |
| `BaseChatMCPE2ETests` | E2E (explicit opt-in smoke) | Nightly smoke only (requires `RUN_MCP_E2E=1`) | `EverythingServerSmokeTests` also needs npx + network | XCTest |
| `BaseChatServerTests` | Unit, Integration | Yes | None | XCTest |
| `BaseChatBackendsTests` | Unit, E2E | Partial | MLX/Llama need Apple Silicon | Mixed |
| `BaseChatTestSupportTests` | Unit | Yes | None | XCTest |
| `BaseChatE2ETests` | E2E | Yes | None (mock backends) | Swift Testing |
| `BaseChatMLXIntegrationTests` | E2E | No | Apple Silicon + Metal + local MLX model | XCTest |
| `BaseChatDemoUITests` | XCUITest | Advisory only (`example-ui-smoke`) | Simulator | XCTest (XCUIApplication) |

### Running tests

```bash
# CI-safe local gate (no hardware required). Two-invocation shape mirrors CI —
# see CLAUDE.md Pre-push checklist for the rationale.
scripts/test.sh --filter BaseChatCoreTests --filter BaseChatRuntimeTests \
  --filter BaseChatPersistenceSwiftDataTests --filter BaseChatUITests \
  --filter BaseChatUIModelManagementTests --filter BaseChatMCPTests \
  --filter BaseChatBackendsTests --filter BaseChatInferenceTests \
  --filter BaseChatTestSupportTests --filter BaseChatAppIntentsTests \
  --filter BaseChatServerTests --disable-default-traits --skip-update

# Swift Testing runs in a separate process to avoid mixed-runner crashes (#681).
# Do NOT add --parallel to BaseChatInferenceTests — the UserDefaults.standard
# race in test_autoSelectFirstRunModel_* and download-tests legacy-key reads
# causes non-deterministic failures (issue #910).
scripts/test.sh --filter BaseChatInferenceSwiftTestingTests \
  --disable-default-traits --skip-update

# Apple Silicon only
swift test --filter BaseChatBackendsTests --traits MLX,Llama

# Additional headless E2E coverage (mock backends; no special hardware)
swift test --filter BaseChatE2ETests --disable-default-traits

# MCP built-in catalog descriptors (trait-gated metadata tests)
scripts/test.sh --filter BaseChatMCPTests --disable-default-traits --traits MCPBuiltinCatalog --skip-update

# MCP end-to-end smoke tests are explicit opt-in only.
# Nightly runs the streamable-HTTP smoke; keep the filter narrow so the
# npx/network-backed EverythingServerSmokeTests suite does not run by default.
RUN_MCP_E2E=1 scripts/test.sh --filter BaseChatMCPE2ESmokeTests \
  --disable-default-traits --skip-update --min-passed 1

# Full subprocess E2E, local only: requires npx on PATH and network access to
# download @modelcontextprotocol/server-everything.
RUN_MCP_E2E=1 swift test --filter EverythingServerSmokeTests --disable-default-traits

# Xcode-only — real MLX model inference (requires local MLX fixture; see below)
# Cannot run via swift test; MLX Metal shaders are only compiled by Xcode.
xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests -destination 'platform=macOS'

# Example app UI tests (preferred debug loop)
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:BaseChatDemoUITests/ChatFlowUITests/testEmptyStateShowsWelcome

# Full UI test sweep when you need it
scripts/example-ui-tests.sh test

# Discover or override the simulator explicitly when needed
xcrun simctl list devices available
scripts/example-ui-tests.sh test-without-building --destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -only-testing:BaseChatDemoUITests/SettingsUITests
```

`build-for-testing` is the expensive step. Run it once, then use `test-without-building` with `-only-testing` for targeted reruns while debugging. The helper prefers a booted iPhone simulator, otherwise the first available iPhone simulator, so contributors do not have to keep stale device names in sync.

### Hardware gating

Tests that need specific hardware skip gracefully rather than failing:

```swift
override func setUp() async throws {
    try await super.setUp()
    try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
}
```

Available flags (from `BaseChatTestSupport/HardwareRequirements.swift`):

| Flag | Meaning |
|------|---------|
| `isAppleSilicon` | Running on arm64 |
| `isPhysicalDevice` | Not the iOS Simulator |
| `hasFoundationModels` | macOS 26+ / iOS 26+ |

### Local MLX model fixture (`BaseChatMLXIntegrationTests`)

`BaseChatMLXIntegrationTests` runs real GPU inference using a model you provide locally. The harness calls `HardwareRequirements.findMLXModelDirectory()` during `setUp`; if no valid directory is found the entire suite is **skipped**, not failed.

**Required fixture shape**

Each model must live in its own subdirectory and contain all three of the following:

| File | Requirement |
|------|-------------|
| `config.json` | Valid JSON with a non-empty `model_type` field |
| `*.safetensors` | At least one weight shard |
| `tokenizer.json` or `tokenizer.model` | Hugging Face tokenizer artifact (either form accepted) |

**Where the harness searches** (in order, first valid directory wins):

1. `~/Documents/Models/<model-dir>/`
2. `~/Library/Containers/*/Data/Documents/Models/<model-dir>/`

Place your MLX snapshot in either location. The harness scans all immediate subdirectories of each `Models/` folder, so a layout like `~/Documents/Models/my-model/` with the files above is sufficient.

**When no fixture is found**

The suite calls `XCTSkip` and is marked skipped — CI sees a green pass, not a failure. You only need a local fixture when you're actively working on `BaseChatMLXIntegrationTests` or `MLXBackend`.

### MLX KV-cache reuse regression checks

Issue #749's prompt-cache reuse path has an extra validation bar beyond "still generates text":

1. **Correctness** — warm second-turn output must match the cold path under deterministic settings.
2. **Real cache hit** — the warm path must emit `GenerationEvent.kvCacheReuse(...)`.
3. **Measured improvement** — warm second-turn TTFT must materially beat the cold path for a long shared prefix.

The Xcode-only suite lives in `BaseChatMLXIntegrationTests/MLXKVPersistenceIntegrationTests.swift`. Run it with:

```bash
xcodebuild test -scheme BaseChatKit-Package \
  -only-testing:BaseChatMLXIntegrationTests/MLXKVPersistenceIntegrationTests \
  -destination 'platform=macOS'
```

When bumping `mlx-swift-lm` or `mlx-swift`, rerun both MLX integration targets before trusting the update:

```bash
xcodebuild test -scheme BaseChatKit-Package \
  -only-testing:BaseChatMLXIntegrationTests/MLXModelE2ETests \
  -only-testing:BaseChatMLXIntegrationTests/MLXKVPersistenceIntegrationTests \
  -destination 'platform=macOS'
```

If the fixture model is VLM/MoE-only, the KV-cache suite skips by design — v1 reuse is intentionally scoped to text-only MLX models.

---

## Feature Coverage Matrix

This matrix maps every major feature area to its current test coverage and identifies gaps.

### Chat & Messaging

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Send message | - | ChatViewModelIntegrationTests | - | ChatFlowUITests | - |
| Stream tokens | - | StreamingFailureTests | CloudBackendSSETests | - | - |
| Cancel mid-stream | - | CancellationTests | - | - | No headless E2E |
| Partial content on error | - | StreamingFailureTests | - | - | - |
| Empty stream cleanup | - | StreamingFailureTests | - | - | - |
| Edit user message | - | - | - | - | **No tests** |
| Regenerate response | - | ConcurrencyTests | - | - | - |
| Pin messages | - | PinMessageTests | - | - | - |
| Copy message | - | - | - | - | **No tests** (UI-only) |
| Markdown rendering | - | AssistantMarkdownRenderingTests | - | - | - |
| Loop detection | - | ChatViewModelLoopDetectionTests | - | - | No E2E for detect-and-stop |
| Token batching | - | StreamingTokenBatcherTests | - | - | - |
| Unicode preservation | - | StreamingFailureTests | - | - | - |
| Large token count (1000) | - | StreamingFailureTests | - | - | - |

### Sessions

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Create session | - | SessionManagerViewModelTests | - | SessionManagementUITests | - |
| Switch session | - | ConcurrencyTests | - | SessionManagementUITests | - |
| Delete session | - | SessionManagerViewModelTests | - | SessionManagementUITests | - |
| Auto-rename | - | SessionAutoRenameTests | - | - | - |
| Switch mid-generation | - | ConcurrencyTests | - | - | No headless E2E |
| Per-session overrides | ChatSessionTests | - | - | - | No integration test |
| Session isolation | - | PersistenceIntegrationTests | - | - | - |

### Context & Compression

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Token estimation | ContextWindowManagerTests | - | - | - | - |
| Message trimming | ContextWindowManagerTests | - | ContextOverflowE2ETests | - | - |
| Budget calculation | ContextWindowManagerTests | - | ContextOverflowE2ETests | - | - |
| Extractive compression | CompressionTests | - | - | - | No E2E |
| Anchored compression | CompressionTests | - | - | - | No E2E |
| Auto-compress at threshold | CompressionTests | CompressionIntegrationTests | - | - | **No E2E for full flow** |
| Pinned messages survive compression | CompressionTests | - | - | - | - |
| Compression stats display | - | CompressionStatsDisplayTests | - | - | - |

### Model Management

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Discover local models | ModelStorageServiceTests | - | - | - | - |
| Download from HuggingFace | DownloadManagerTests | BackgroundDownloadIntegrationTests | DownloadValidationE2ETests | - | - |
| GGUF validation | - | - | DownloadValidationE2ETests | - | - |
| MLX validation | - | - | DownloadValidationE2ETests | - | - |
| Delete models | ModelStorageServiceTests | - | - | - | - |
| Storage accounting | - | - | - | ModelManagementUITests | No headless test |
| GGUF metadata reading | GGUFMetadataReaderTests | - | - | - | - |
| Template detection | PromptTemplateDetectorTests | - | - | - | - |
| Device-aware recommendations | DeviceCapabilityServiceTests | - | - | - | - |

### Remote Backends & Cloud APIs

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| OpenAI SSE streaming | - | - | CloudBackendSSETests | - | - |
| Claude SSE streaming | - | - | CloudBackendSSETests | - | - |
| Auth errors (401) | - | - | CloudBackendSSETests | - | - |
| Rate limiting (429) | - | - | CloudBackendSSETests | - | - |
| Malformed SSE handling | - | - | CloudBackendSSETests | - | - |
| Connection drop mid-stream | - | - | CloudBackendSSETests | - | - |
| API endpoint config | APIEndpointTests | - | - | CloudAPIUITests | - |
| Keychain storage | KeychainServiceTests | - | - | - | - |
| Certificate pinning | - | PinnedSessionDelegateTests | - | - | - |
| Retry with backoff | RetryPolicyTests | - | - | - | **No integration test** |

### Generation & Prompt Assembly

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Prompt template formatting | PromptTemplateTests | - | - | - | - |
| Prompt slot assembly | PromptAssemblerTests | - | ContextOverflowE2ETests | - | - |
| Sampler presets | SamplerPresetTests | - | - | - | No integration test |
| System prompt templating | - | ChatViewModelSystemPromptContextTests | - | - | - |
| Generation settings | GenerationConfigTests | GenerationViewModelTests | - | SettingsUITests | - |
| Backend capabilities | BackendCapabilitiesTests, BackendCapabilityMatrixTests | BackendVisionCapabilityTests | - | - | Claims must match supported tool/vision/JSON behavior |
| Backend contract | BackendContractTests | - | - | - | - |

### System & Lifecycle

| Feature | Unit | Integration | E2E | XCUITest | Gap? |
|---------|------|-------------|-----|----------|------|
| Memory pressure handling | MemoryPressureHandlerTests | - | - | - | **No E2E** |
| Chat export | ChatExportServiceTests | - | - | - | - |
| Concurrent access safety | - | ConcurrencyTests, MemoryAndConcurrencyTests | - | - | - |
| Rapid sends | - | ConcurrencyTests | - | - | - |
| Model load/unload mid-gen | - | CancellationTests | - | - | - |

---

## Async Testing Patterns

AI applications are inherently asynchronous: tokens stream one at a time, generation can be cancelled, sessions can switch mid-stream, and network connections can drop. Testing these flows requires specific patterns.

### Pattern 1: Await the Full Operation

The simplest pattern. Call an async method and assert the result:

```swift
func test_sendMessage_persistsToDatabase() async {
    vm.inputText = "Hello"
    await vm.sendMessage()  // Blocks until generation completes

    XCTAssertEqual(vm.messages.count, 2)  // user + assistant
}
```

**When to use:** Testing the happy path where you don't need to interact mid-stream.

**Used in:** `ChatViewModelIntegrationTests`, `StreamingFailureTests`

### Pattern 2: Fire-and-Poll for Mid-Stream Interaction

When you need to act *during* generation (cancel, switch session, unload model), launch generation in a detached `Task` and poll for the right moment:

```swift
func test_stopGeneration_midStream() async throws {
    vm.inputText = "Hello"
    let sendTask = Task { await vm.sendMessage() }

    // Poll until at least one token has arrived
    for _ in 0..<100 {
        if vm.messages.count >= 2, !(vm.messages.last?.content ?? "").isEmpty { break }
        try await Task.sleep(for: .milliseconds(20))
    }

    vm.stopGeneration()
    await sendTask.value  // Wait for cleanup

    XCTAssertFalse(vm.isGenerating)
    XCTAssertFalse(vm.messages[1].content.isEmpty, "Partial content preserved")
}
```

**When to use:** Cancellation, session switching mid-generation, model unloading mid-generation.

**Why polling instead of a callback?** The ViewModel doesn't expose "first token arrived" as an event. Polling with tight sleeps (20ms) is pragmatic and fast. The total timeout (100 * 20ms = 2s) is generous enough for CI.

**Used in:** `CancellationTests`, `ConcurrencyTests`

### Pattern 3: SlowMockBackend for Timing Control

`SlowMockBackend` yields tokens with a configurable delay, giving tests control over how long generation takes:

```swift
slowBackend.tokensToYield = (0..<20).map { "t\($0) " }
slowBackend.delayPerToken = .milliseconds(50)  // 20 tokens * 50ms = ~1 second total
```

This makes mid-stream interactions predictable. A 150ms sleep will reliably land after 3 tokens have been emitted.

**When to use:** Any test that needs to interact during generation.

### Pattern 4: MidStreamErrorBackend for Error Injection

`MidStreamErrorBackend` yields N tokens then throws, simulating a backend that fails partway through:

```swift
let backend = MidStreamErrorBackend(
    tokensBeforeError: ["Hello", " world"],
    errorToThrow: InferenceError.inferenceFailure("Connection lost")
)
```

**When to use:** Testing error recovery, partial content preservation, error message display.

**Used in:** `StreamingFailureTests`

### Pattern 5: MockURLProtocol for Network Simulation

For cloud backends, `MockURLProtocol` intercepts HTTP requests and returns canned responses, including chunked SSE streams:

```swift
let chunks: [Data] = [
    "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hello\"}}\n\n".data(using: .utf8)!,
    "data: {\"type\":\"message_stop\"}\n\n".data(using: .utf8)!,
]
MockURLProtocol.stub(url: endpoint, response: .sse(chunks: chunks, statusCode: 200))
```

**When to use:** Testing SSE parsing, auth errors, rate limiting, connection drops — all without a real server.

**Used in:** `CloudBackendSSETests`

### Pattern 6: Concurrent Task Spawning

For testing race conditions, spawn multiple tasks that compete for shared state:

```swift
var tasks: [Task<Void, Never>] = []
for i in 0..<5 {
    vm.inputText = "Rapid message \(i)"
    let task = Task { @MainActor in await self.vm.sendMessage() }
    tasks.append(task)
}
for task in tasks { await task.value }

// Assert: no crash, messages non-empty, timestamps monotonic
```

**When to use:** Rapid sends, concurrent session creation, race condition detection.

**Used in:** `ConcurrencyTests`, `MemoryAndConcurrencyTests`

### Pattern 7: XCTestExpectation for Delegate Callbacks

For APIs that use callbacks rather than async/await (e.g., URLSession delegates):

```swift
let expectation = XCTestExpectation(description: "delegate called")
delegate.onComplete = { expectation.fulfill() }

// Trigger the operation
session.dataTask(with: request).resume()

await fulfillment(of: [expectation], timeout: 2.0)
```

**When to use:** Only for callback-based APIs. Prefer `async/await` for everything else.

**Used in:** `PinnedSessionDelegateTests`

### Anti-patterns to avoid

| Anti-pattern | Why it's bad | Do this instead |
|-------------|-------------|-----------------|
| `Thread.sleep()` | Blocks the thread, can deadlock @MainActor | `Task.sleep(for:)` |
| Fixed long sleeps (`sleep(2)`) | Slow in CI, still flaky | Poll with short intervals + deadline |
| `DispatchSemaphore` in async code | Can deadlock with Swift concurrency | Use `async/await` or `AsyncStream` |
| `XCTestExpectation` for async code | Verbose, timeout-dependent | `await` the async method directly |
| Mocking `Task.sleep` | Over-engineering | Use `SlowMockBackend` to control timing |

---

## AI-Specific Flow Testing

AI chat applications have unique testing challenges that traditional app testing doesn't address. Here are the patterns specific to LLM-backed chat.

### Streaming Token Flows

Unlike a REST API that returns a complete response, LLM backends stream tokens one at a time. This creates several testable states:

```
[idle] → [generating: 0 tokens] → [generating: N tokens] → [complete]
                                        ↓
                                  [error: partial content]
                                        ↓
                                  [cancelled: partial content]
```

Each transition is tested:
- `idle → complete`: `ChatViewModelIntegrationTests.test_sendMessage_persistsUserAndAssistantToDatabase`
- `generating → cancelled`: `CancellationTests.test_stopGeneration_midStream_stopsTokenFlow`
- `generating → error`: `StreamingFailureTests.test_streamError_midStream_preservesPartialContent`
- `generating → complete (empty)`: `StreamingFailureTests.test_emptyStream_removesAssistantPlaceholder`

### Multi-Turn Conversation

AI conversations are stateful — each turn builds on the last. Tests must verify:

1. **Message ordering** — user/assistant pairs are interleaved correctly
2. **Context accumulation** — previous messages are sent to the backend
3. **Session isolation** — switching sessions doesn't leak messages
4. **Persistence** — all turns survive app restart (SwiftData)

```swift
// From ChatViewModelIntegrationTests
func test_multiTurnConversation_allMessagesPersisted() async {
    // Turn 1
    vm.inputText = "First question"
    await vm.sendMessage()
    // Turn 2
    vm.inputText = "Follow-up"
    await vm.sendMessage()
    // Turn 3
    vm.inputText = "One more"
    await vm.sendMessage()

    XCTAssertEqual(vm.messages.count, 6)  // 3 user + 3 assistant
    // Verify database has all 6 messages
}
```

### Context Window Pressure

LLMs have finite context windows. As conversations grow, older messages must be trimmed or compressed. Testing this requires:

1. **Deterministic token counting** — `CharTokenizer` (1 char = 1 token) makes budgets predictable
2. **Controlled context sizes** — test with tiny windows (50-512 tokens) to trigger trimming
3. **Boundary assertions** — verify the newest message is always preserved, even when the budget is exceeded

```swift
// From ContextOverflowE2ETests — real components, no mocks
@Test func progressiveTruncation_keepsNewest() async throws {
    let assembler = PromptAssembler(tokenizer: HeuristicTokenizer())
    // ... fill context past budget ...
    // Assert: most recent message always survives
}
```

### Cancellation Semantics

When a user taps "Stop", the contract is:
1. Token streaming stops (no new tokens appended)
2. Partial content is preserved (not discarded)
3. `isGenerating` becomes `false`
4. The user can send a new message immediately

Each guarantee has a dedicated test in `CancellationTests`.

### Loop Detection

LLMs sometimes get stuck repeating the same phrase. `RepetitionDetector` catches this and auto-stops generation. Tests verify:
- Detection threshold (how many repeats trigger it)
- That generation stops when a loop is detected
- That the partial (pre-loop) content is preserved

### Error Recovery

AI backends fail in ways traditional APIs don't:
- **Mid-stream errors** — the backend crashes after sending some tokens
- **Empty responses** — the model generates nothing
- **Malformed SSE** — the cloud API sends bad JSON
- **Connection drops** — the network dies mid-stream

Each failure mode is tested with purpose-built mock backends (`MidStreamErrorBackend`, `MockURLProtocol`).

### Concurrency Under AI Workloads

Users do unexpected things during generation:
- Send another message while generating
- Switch to a different conversation
- Unload the model
- Close the app

`ConcurrencyTests` covers all of these with `SlowMockBackend`, verifying no crashes, no data corruption, and correct state cleanup.

---

## Mock Infrastructure

All shared test infrastructure lives in `Sources/BaseChatTestSupport/`:

### Mock Backends

| Mock | Purpose | Key Feature |
|------|---------|-------------|
| `MockInferenceBackend` | General-purpose fast backend | Configurable tokens, call tracking, argument capture |
| `SlowMockBackend` | Timing-controlled backend | Per-token delay, cancellation support via `Task.isCancelled` |
| `MidStreamErrorBackend` | Error injection | Yields N tokens then throws a configurable error |
| `TokenTrackingMockBackend` | Token usage reporting | Tracks prompt/completion token counts per call |
| `MockTokenizerVendorBackend` | Tokenizer provision | Backend that also provides a tokenizer with stubbed counts |

### Service Mocks

| Mock | Purpose |
|------|---------|
| `MockHuggingFaceService` | Stubs HF search results, tracks call counts |
| `InMemoryPersistenceHarness` | Fresh in-memory `SwiftDataPersistenceProvider` stack — preferred over mocked storage |
| `ErrorInjectingPersistenceProvider` | Wraps any `ChatPersistenceProvider` to add per-method error injection and call counting |
| `MockURLProtocol` | HTTP interception with immediate, SSE (chunked), and error modes |

### Utilities

| Utility | Purpose |
|---------|---------|
| `CharTokenizer` | Deterministic tokenizer: 1 character = 1 token |
| `HardwareRequirements` | Static flags for `XCTSkipUnless` hardware gating |
| `TestHelpers.makeInMemoryContainer()` | Creates ephemeral SwiftData ModelContainer |

### Design principles for mocks

1. **Protocol witnesses, not subclasses.** Every mock implements a protocol (`InferenceBackend`, `ChatPersistenceProvider`, etc.). This is idiomatic Swift and avoids fragile base class problems.

2. **Thread-safe.** Mocks that might be accessed from multiple isolation domains use `NSLock` or `@MainActor`. `SlowMockBackend` uses `NSLock` for its token state; `MockHuggingFaceService` uses `OSAllocatedUnfairLock`.

3. **Call tracking.** Mocks expose `loadModelCallCount`, `generateCallCount`, etc. for verifying interactions.

4. **Configurable failure.** Every mock can be told to throw on specific operations, enabling negative-path testing without complex setup.

---

## Writing New Tests

### Choosing the right layer

Ask these questions in order:

1. **Can this be tested with just the type and its direct dependencies?** → Unit test in `BaseChatCoreTests`
2. **Does it need ChatViewModel + SwiftData + a mock backend?** → Integration test in `BaseChatUITests`
3. **Does it need real (non-mock) components wired together?** → E2E test in `BaseChatE2ETests`
4. **Does it need the real UI in a simulator?** → XCUITest in `BaseChatDemoUITests`

### Test structure template

```swift
import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatInference
import BaseChatTestSupport

@MainActor
final class MyFeatureTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: backend, name: "Mock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)
    }

    override func tearDown() async throws {
        vm = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    func test_myFeature_doesExpectedThing() async {
        // Arrange
        let session = // create and activate session

        // Act
        vm.inputText = "Test input"
        await vm.sendMessage()

        // Assert
        XCTAssertEqual(vm.messages.count, 2)
    }
}
```

### Sabotage check

After your test passes, temporarily break the code path being tested and confirm the test fails. This catches tests that pass for the wrong reason (e.g., assertions against the wrong variable). Remove the sabotage before committing.

### Naming conventions

- **Test files:** `{Feature}Tests.swift` for unit, `{Feature}IntegrationTests.swift` for integration, `{Feature}E2ETests.swift` for E2E
- **Test methods:** `test_{method}_{scenario}_{expected}` — e.g., `test_stopGeneration_midStream_preservesPartialContent`
- **Placement:** Match the target that owns the code being tested. ViewModel tests go in `BaseChatUITests`, service tests in `BaseChatCoreTests`, backend tests in `BaseChatBackendsTests`.

### Framework choice

- **Existing files:** Match whatever the file already uses (XCTest or Swift Testing)
- **New files:** Use XCTest (`XCTestCase`) for new test suites — this is the project convention
- **Swift Testing** (`@Suite`, `@Test`, `#expect`): Used in some newer E2E tests. Fine for pure logic tests, but XCTest is better for tests needing `setUp`/`tearDown` lifecycle management

---

## withKnownIssue Policy

Swift Testing's `withKnownIssue` lets you mark a failing assertion as an expected failure so the test suite stays green while the underlying bug is tracked. Use it sparingly — it is test debt, not a fix.

### When it is acceptable

- The failure is caused by a confirmed bug in the system under test (not a flaky test or bad assertion).
- A tracking issue exists and is linked in the wrapper comment.
- The wrapper is scoped as tightly as possible — only the failing assertion, not the whole test body.

```swift
// FIXME: https://github.com/your-org/BaseChatKit/issues/123 — context boundary off-by-one under compression
withKnownIssue("context trim drops one message too many, tracked in #123") {
    #expect(vm.messages.count == 4)
}
```

### When it is not acceptable

- You do not have a tracking issue — open one before adding the wrapper.
- The failure is in a critical E2E path (full chat turn, download → load → generate, cancellation). Known issues in E2E coverage must be resolved promptly; they represent gaps in your safety net.
- The underlying issue is already fixed — remove the wrapper in the same PR that fixes the bug.

### Lifecycle rules

| Stage | Action |
|-------|--------|
| Adding `withKnownIssue` | Link the tracking issue in a `// FIXME:` comment on the line above |
| Issue is fixed | Remove the wrapper in the same PR; do not leave it as a no-op |
| PR review | Reviewers should block any `withKnownIssue` that lacks a tracking issue link |
| E2E known issues | Escalate — treat them as P1 bugs, not deferred polish |

A `withKnownIssue` that survives more than one release without a linked fix plan is a sign the feature lacks real coverage. Prefer a `XCTSkipIf` with a comment if the scenario genuinely cannot be tested yet, and file a separate tracking issue.

---

## Known Gaps

These are features or flows that lack adequate test coverage. They represent the highest-value areas for new test contributions.

### E2E Flows (no headless E2E exists)

| Flow | What to test | Suggested approach |
|------|-------------|-------------------|
| **Full chat turn** | Send → stream → persist → reload | Wire real ViewModel + MockBackend + in-memory SwiftData. Verify messages survive `switchToSession` round-trip. |
| **Compression under pressure** | Fill context → auto-compress → continue generating | Use `CharTokenizer` with a tiny context window (100 tokens). Send enough messages to trigger compression. Verify generation continues with compressed context. |
| **Download → validate → load → generate** | Download model → validate files → load backend → generate tokens | End-to-end with real filesystem (temp dir). Currently download validation and generation are tested separately. |
| **Loop detect → auto-stop** | Generate repetitive tokens → detector fires → generation stops | Use `MockInferenceBackend` with repeating tokens. Verify `RepetitionDetector` triggers and partial content is preserved. |
| **Memory pressure → unload** | Memory warning fires → model unloaded → user informed | Requires simulating memory pressure dispatch source. |

### Integration Tests (missing or thin)

| Area | What to test |
|------|-------------|
| **Per-session generation overrides** | Session with custom temperature/topP → verify backend receives correct config |
| **Retry policy under real network errors** | RetryPolicy + real URLSession error → verify backoff timing and retry count |
| **Sampler preset round-trip** | Save preset → reload → apply to generation config → verify values match |
| **Export with real conversation data** | Generate a multi-turn conversation → export as markdown → verify format |

### UI Tests (structural gaps)

| Area | What to test |
|------|-------------|
| **Edit message flow** | Tap edit → modify text → save → verify message updated |
| **Compression mode picker** | Switch modes in settings → verify compression behavior changes |
| **Prompt inspector** | Open inspector → verify slot breakdown matches assembled prompt |
| **Error banner display** | Trigger backend error → verify banner appears and dismisses |

### Preview Assertions

The 26 SwiftUI previews compile but are not snapshot-tested. Adding snapshot tests (e.g., with `swift-snapshot-testing`) would catch visual regressions without XCUITest overhead.

### Timing Robustness

16 tests use `Task.sleep` for timing. While functional, these can be flaky under CI load. Consider migrating to event-driven patterns where the ViewModel exposes observable state changes that tests can await directly, rather than polling.

---

## Classification audit — 2026-04-19

Full `Tests/**/*Tests.swift` walk (173 files) against the CLAUDE.md taxonomy:

- **Unit** — no external process, no network, no filesystem beyond `Bundle.module`, no `localhost` services, no real model loading, no SwiftData.
- **Integration** — SwiftData in-memory store, real file I/O in a temp dir, mocked URL sessions via `MockURLProtocol`. No external services, no real model weights.
- **E2E** — real model load (MLX metallib, Llama GGUF, Foundation system model) or real network (Ollama daemon, Claude/OpenAI cloud) or real hardware.

This project additionally uses a "Layer 4 — Headless E2E" bucket (see [Testing Pyramid](#testing-pyramid)) for suites that wire real production components (ViewModel + SwiftData + real services) with only the inference backend stubbed. Those are catalogued below as E2E *(headless)*.

### Findings

| File | Location | Declared | Honest classification | Action |
|---|---|---|---|---|
| `LlamaBackendLoadSerializationCharacterizationTests.swift` | `BaseChatBackendsTests` | Characterization / integration | **E2E** — requires real GGUF on disk + Apple Silicon + Metal via `HardwareRequirements.findGGUFModel()` | **Moved** to `BaseChatE2ETests/LlamaBackendLoadSerializationCharacterizationE2ETests.swift`; class renamed to match. Pairs with the existing `LlamaE2ETests.swift` which also requires a real GGUF. |
| `SwiftDataPersistenceProviderTests.swift` | `BaseChatCoreTests` | Docstring said "Unit tests" | **Integration** — uses a real in-memory SwiftData `ModelContainer` on every test. | **Docstring fixed**; file location is correct (the target intentionally mixes Unit + Integration, per the Test Targets table above). No rename — existing references across the repo are stable. |

No other `*Tests.swift` file is clearly mislabeled. The remaining suspicions called out in the audit brief resolved as follows.

### Intentional exceptions

- **`OllamaBackendTests.swift`** (BaseChatBackendsTests) — despite hitting code paths for Ollama, every test uses `MockURLProtocol` with UUID-scoped hostnames. No process ever contacts `localhost:11434`. Correctly classified as unit / integration in the Backends target. The real daemon E2E lives in `BaseChatE2ETests/OllamaE2ETests.swift` behind `HardwareRequirements.hasOllamaServer`.
- **`FoundationBackendUnitTests.swift`** (BaseChatBackendsTests) — the filename states "unit". It uses `ProcessInfo` + `XCTSkip` to skip before iOS 26 / macOS 26, does not instantiate the system language model, and exercises only state-machine guards. Honest. The paired E2E path lives in `FoundationModelE2ETests.swift` (same target) which runs real Apple Intelligence inference.
- **`FoundationModelE2ETests.swift`** (BaseChatBackendsTests) — named E2E, loads the real system model, skips on unsupported OS. Located in `BaseChatBackendsTests` for convenience of `#if canImport(FoundationModels)`. Doesn't run in CI on older SDKs (skips). Left as-is; flagging rather than relocating because the move would cost a conditional-compile guard without buying separation of concerns — the skip is airtight.
- **`MLXBackendTests.swift` / `MLXBackendGenerationTests.swift` / `MLXBackendThinkingTests.swift` / `MLXCachePolicyTests.swift`** (BaseChatBackendsTests, `#if MLX`) — all use `MockMLXModelContainer` injected via `MLXBackend._inject`. No real weights loaded. Hardware-gated paths (`test_loadModel_invalidDirectory_throws`) exercise negative filesystem paths only. Honest as Backends target unit/integration.
- **`LlamaBackendTests.swift` / `LlamaBackendMemoryPressureTests.swift`** (BaseChatBackendsTests, `#if Llama`) — instantiate `LlamaBackend` (which calls `llama_backend_init` on Metal) but never load a real GGUF. Skip on simulator / non-Apple-Silicon. Honest as hardware-gated integration in the Backends target; not E2E because they don't load real weights.
- **`CloudBackendSSETests.swift`** (BaseChatBackendsTests, titled "Claude Backend SSE E2E") — uses `MockURLProtocol`, not real cloud APIs. Named E2E per this project's "Layer 4 — Headless E2E" convention documented in the Testing Pyramid. Not relocated because the convention is intentional and consistent with `ChatTurnRoundTripE2ETests`, `LoopDetectionE2ETests`, `ContextOverflowE2ETests`, etc., which also live in `BaseChatE2ETests` without hitting real backends.
- **`ContextOverflowE2ETests.swift`** (BaseChatE2ETests) — pure computation over `PromptAssembler` + `HeuristicTokenizer`. No backend, no persistence, no I/O. Would be a unit test by the strict taxonomy; kept in `BaseChatE2ETests` because TESTING.md explicitly defines Layer 4 as "real components wired together ... with only the inference backend mocked". Passing a full prompt through the real assembler pipeline fits that definition.
- **`DownloadValidationE2ETests.swift` / `DownloadValidateLoadGenerateE2ETests.swift`** (BaseChatE2ETests) — use real filesystem temp dirs and the real `BackgroundDownloadManager`. No network. Under the strict taxonomy these are integration tests; under the project's Layer-4 definition they qualify as headless E2E. Honest per the project convention.
- **`BaseChatMLXIntegrationTests/MLXModelE2ETests.swift`** — target is named `...IntegrationTests` (legacy) but the file and class are `MLXModelE2ETests` and the suite loads a real MLX model through Metal. The CLAUDE.md Targets table already classifies this target as "Xcode-only real MLX model E2E tests", so the naming mismatch is cosmetic. Left as-is to avoid churning the Xcode scheme + CI exclusion rules.
- **`BaseChatBackendsTests/AllBackendsAcceptPlanTests.swift` / `OpenAICompatEndpointTests.swift` / `CloudEndpointSelectionIntegrationTests.swift`** — all reference `http://localhost:11434` only as configuration strings; none perform actual requests without `MockURLProtocol` interception.
- **`BaseChatCoreTests/APIEndpointTests.swift` / `APIEndpointValidationTests.swift` / `CustomEndpointValidationTests.swift`** — localhost URLs appear only as test input data passed to pure validation logic. No network activity.
- **`BaseChatUITests/APIConfigurationLogicTests.swift`** — localhost reference is a string-equality assertion on `APIProvider.defaultBaseURL`. Pure unit.
- **`BaseChatInferenceTests/SilentCatchAuditTest.swift`** — scans `Sources/*.swift` on disk at test time, so technically integration (filesystem I/O) rather than unit. Documented in file header as a source-audit check; treated as a "static analysis" lint-like test. Location in `BaseChatInferenceTests` is fine; not relocated.
- **`BaseChatInferenceTests/KeychainIntegrationTests.swift`** — hits the real macOS/iOS Keychain via `SecItem`. Correctly named, correctly located.
- **`BaseChatInferenceTests/BackgroundDownloadIntegrationTests.swift`** — real filesystem persistence. Correctly named.
- **`BaseChatUITests/PersistenceIntegrationTests.swift` / `ChatExportIntegrationTests.swift` / `ContextEstimationIntegrationTests.swift` / `ChatViewModelIntegrationTests.swift` / `ChatViewModelScenePhaseIntegrationTests.swift` / `EditUserMessageIntegrationTests.swift`** — all honestly named integration suites that wire ChatViewModel + SwiftData + mock backends.
- **`BaseChatUITests/*Tests.swift` without the `Integration` suffix** (e.g. `CancellationTests`, `ConcurrencyTests`, `PinMessageTests`, `SessionOverrideTests`) — most exercise ChatViewModel + SwiftData + mock and are therefore integration by the strict taxonomy, but live in `BaseChatUITests` which TESTING.md classifies as "Integration" in its Test Targets table. The naming is loose by project convention, not dishonest.
- **`BaseChatInferenceTests/HuggingFaceServiceTests.swift`** — uses `MockURLProtocol`; no real HuggingFace traffic.
- **`BaseChatFuzzTests/FindingsSinkTests.swift`** — uses a temp-dir sink, so strictly integration. Other files in the fuzz target are pure unit. Located with the rest of the fuzz suite; no move.
- **`BaseChatBackendsTests/LlamaBackendMemoryPressureTests.swift`** — contains a hardware-free unit portion (callback API) at the top and an `#if Llama` hardware-gated portion at the bottom. Both are honest as written.

### Actions taken in this PR

1. `git mv Tests/BaseChatBackendsTests/LlamaBackendLoadSerializationCharacterizationTests.swift Tests/BaseChatE2ETests/LlamaBackendLoadSerializationCharacterizationE2ETests.swift` — real-GGUF test moved to its correct target.
2. Class rename: `LlamaBackendLoadSerializationCharacterizationTests` → `LlamaBackendLoadSerializationCharacterizationE2ETests` for matching naming. No external references to update (grep clean).
3. `SwiftDataPersistenceProviderTests.swift` header docstring: "Unit tests" → "Integration tests", with an explicit pointer to this audit.
4. This section added to TESTING.md.

No other relocations were needed. The audit confirms the `BaseChatE2ETests` suite is honestly named under the project's documented Layer 4 definition, and that `BaseChatBackendsTests` no longer contains any file that loads real model weights.

---

## Ollama tool-call fixture corpus

Two fixture corpora live at `Tests/Fixtures/ollama/tool-calls/`:

- `adversarial/` — 15+ hand-crafted NDJSON lines, each with an
  `.expected.json` sibling describing the outcome a compliant parser must
  produce (emit / no-emit, tool_name, arguments substring, warning
  behaviour). Covers wire-format drift observed in the wild: `arguments`
  as object vs string, missing `id`, OpenAI-compat vs flat shape,
  unicode, surrogate pairs, long payloads, malformed JSON, Python
  literals.
- `<OLLAMA_VERSION>/` (currently `0.3.12/`) — full NDJSON stream captures
  (`<scenario>.sse` + `<scenario>.expected.jsonl`) representing real
  server traces at a pinned Ollama version. A `VERSION.md` sibling
  documents the pin and the re-capture procedure.

### CI version pinning

The real-daemon E2E job sets `OLLAMA_VERSION=0.3.12` and asserts that
`ollama --version` contains that string before running any fixtures. When
Ollama is bumped:

1. Re-capture the `.sse` fixtures against the new version — see
   `Tests/Fixtures/ollama/tool-calls/0.3.12/VERSION.md` for the procedure.
2. Rename the directory to the new version.
3. Update `OLLAMA_VERSION` in the CI workflow (or in `TESTING.md` here if
   the workflow doesn't yet exist).
4. Delete the old directory only after the new fixtures are green.

### Replay test harnesses

- `OllamaAdversarialJSONTests` — walks the `adversarial/` corpus.
- `OllamaToolCallLiveReplayTests` — walks the pinned-version `.sse`
  captures.

Both gate tool-call assertions on
`OllamaBackend().capabilities.supportsToolCalling` so they activate
automatically when Ollama tool-call emission lands in `OllamaBackend`.
