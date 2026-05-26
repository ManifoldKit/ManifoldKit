import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Receipt-order guarantee for parallel tool-call emission.
///
/// Complements ``ToolCallContractTests`` (single-call baseline) and
/// ``ToolCallStreamingContractTests`` (interleaved *delta* ordering).
/// This file focuses exclusively on the ordering of complete
/// ``GenerationEvent/toolCall(_:)`` events when a backend reports
/// ``BackendCapabilities/supportsParallelToolCalls``.
///
/// **Scope split:** tests 1–3 assert on the backend-level stream
/// directly (`MockInferenceBackend.generate(...)`) so any future
/// reordering or buffering introduced *inside the backend* is caught
/// without coordinator-side noise. Test 4 routes through
/// `GenerationQueue` to lock in the higher-level callId↔result
/// association contract. The two layers exercise different invariants
/// and intentionally use different harnesses.
///
/// All tests use deterministic mock sequences — no wall-clock races,
/// no `sleep`, no timing-based assertions.
@MainActor
final class ParallelToolCallOrderingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a mock backend with `supportsParallelToolCalls` set to the
    /// supplied value. All other capabilities are minimal defaults.
    private func makeBackend(parallel: Bool) -> MockInferenceBackend {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            supportsParallelToolCalls: parallel
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        backend.tokensToYield = []
        return backend
    }

    /// Drain every `.toolCall` event from a stream, in the order received.
    private func collectToolCalls(
        _ stream: GenerationStream
    ) async throws -> [ToolCall] {
        var calls: [ToolCall] = []
        for try await event in stream.events {
            switch event {
            case .toolCall(let c):
                calls.append(c)
            case .prefillProgress, .token, .usage,
                 .thinkingToken, .thinkingComplete, .thinkingSignature,
                 .toolResult, .toolProgress, .toolLoopLimitReached,
                 .kvCacheReuse, .diagnosticThrottle,
                 .toolCallStart, .toolCallArgumentsDelta,
                 .toolDispatchStarted, .toolDispatchCompleted,
                 .handoffRequested:
                break
            }
        }
        return calls
    }

    // MARK: - 1. Two parallel calls arrive in emission order

    /// A parallel-capable backend emitting `.toolCall(A)` then `.toolCall(B)`
    /// must surface those events in the same order: `["A-id", "B-id"]`.
    ///
    /// The ordering guarantee is receipt order (stream position), not
    /// alphabetical sort and not sorted by `toolName`.
    ///
    /// Sabotage: reverse the scripted emission order to `[callB, callA]` and
    /// the assertion `callIds == ["A-id", "B-id"]` detects the swap.
    func test_parallelBackend_emitsToolCallsInReceiptOrder() async throws {
        let backend = makeBackend(parallel: true)
        XCTAssertTrue(
            backend.capabilities.supportsParallelToolCalls,
            "pre-condition: backend must report supportsParallelToolCalls"
        )

        let callA = ToolCall(id: "A-id", toolName: "tool_z", arguments: "{}")
        let callB = ToolCall(id: "B-id", toolName: "tool_a", arguments: "{}")
        // Script: A then B. (Deliberately alphabetically reversed by name to
        // confirm the test does not rely on name order.)
        backend.scriptedToolCalls = [callA, callB]

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: .init())
        let received = try await collectToolCalls(stream)

        // Sabotage check: swap [callA, callB] → [callB, callA] in scriptedToolCalls
        // and the assertion below detects the reordering.
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.map(\.id), ["A-id", "B-id"])
    }

    // MARK: - 2. Three parallel calls arrive in emission order

    /// Receipt-order guarantee holds for a three-call batch.
    ///
    /// Sabotage: reorder the scripted sequence to `[C, A, B]` and the
    /// assertion `callIds == ["A-id", "B-id", "C-id"]` fails.
    func test_parallelBackend_threeCallsInReceiptOrder() async throws {
        let backend = makeBackend(parallel: true)

        let callA = ToolCall(id: "A-id", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        let callB = ToolCall(id: "B-id", toolName: "get_time",    arguments: #"{"tz":"UTC"}"#)
        let callC = ToolCall(id: "C-id", toolName: "get_news",    arguments: #"{"topic":"tech"}"#)
        backend.scriptedToolCalls = [callA, callB, callC]

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: .init())
        let received = try await collectToolCalls(stream)

        // Sabotage check: reordering to [callC, callA, callB] makes
        // received.map(\.id) == ["C-id", "A-id", "B-id"], failing the assertion.
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received.map(\.id), ["A-id", "B-id", "C-id"])
    }

    // MARK: - 3. Sequential backend delivers all calls (no drops)

    /// A backend that serialises tool calls (`supportsParallelToolCalls: false`)
    /// must still deliver every scripted call in receipt order — sequential
    /// serialisation must not cause the second call to be silently dropped or
    /// reordered.
    ///
    /// Sabotage: truncate `scriptedToolCalls` to a single entry and the
    /// count assertion `received.count == 2` catches the drop.
    func test_sequentialBackend_deliversAllCallsWithoutDrops() async throws {
        let backend = makeBackend(parallel: false)
        XCTAssertFalse(
            backend.capabilities.supportsParallelToolCalls,
            "pre-condition: backend must report sequential-only tool calls"
        )

        let call1 = ToolCall(id: "seq-1", toolName: "lookup", arguments: #"{"q":"swift"}"#)
        let call2 = ToolCall(id: "seq-2", toolName: "lookup", arguments: #"{"q":"xcode"}"#)
        backend.scriptedToolCalls = [call1, call2]

        let stream = try backend.generate(prompt: "search", systemPrompt: nil, config: .init())
        let received = try await collectToolCalls(stream)

        // Both calls must arrive; the second must not be silently dropped.
        // Sabotage check: set scriptedToolCalls = [call1] only — received.count
        // becomes 1, failing the equality assertion.
        XCTAssertEqual(received.count, 2, "sequential backend must not drop the second call")
        XCTAssertEqual(received[0].id, "seq-1")
        XCTAssertEqual(received[1].id, "seq-2")
    }

    // MARK: - 4. Parallel calls produce results associated with correct callIds

    /// When two parallel tool calls are dispatched and both executors return
    /// results, each `.toolResult` event must carry the `callId` that
    /// corresponds to its originating `.toolCall` event.
    ///
    /// This test asserts on callId/result *association*, not on the
    /// emission order of `.toolResult` events. The coordinator is free
    /// to dispatch parallel executors concurrently, so result order is
    /// not part of the locked-in contract — only the callId binding is.
    ///
    /// Uses `scriptedToolCallsPerTurn` so the coordinator loop routes
    /// both calls through the tool registry and surfaces `.toolResult` events.
    ///
    /// Sabotage: swap the `callId` values in `call1`/`call2` definitions and
    /// the result-association assertion detects the mismatch.
    func test_parallelCalls_resultsAssociatedWithCorrectCallIds() async throws {
        let backend = makeBackend(parallel: true)

        let call1 = ToolCall(id: "p-1", toolName: "get_weather", arguments: #"{"city":"London"}"#)
        let call2 = ToolCall(id: "p-2", toolName: "get_time",    arguments: #"{"tz":"Europe/London"}"#)

        // Turn 1: emit both parallel calls. Turn 2: quiet (no more tool calls).
        backend.scriptedToolCallsPerTurn = [[call1, call2], []]
        backend.tokensToYieldPerTurn     = [[], ["Done."]]

        let weatherExecutor = SimpleExecutor(name: "get_weather", result: "Cloudy, 15°C")
        let timeExecutor    = SimpleExecutor(name: "get_time",    result: "10:30 BST")

        let registry = ToolRegistry()
        registry.register(weatherExecutor)
        registry.register(timeExecutor)

        // FakeGenerationContextProvider (defined in GenerationQueueTests.swift)
        // is package-internal — wire the coordinator directly instead.
        let provider = DirectProvider(backend: backend)
        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "weather and time in London?")],
            maxOutputTokens: 64
        )

        var toolResults: [ToolResult] = []
        for try await event in stream.events {
            if case .toolResult(let r) = event { toolResults.append(r) }
        }

        // Both results must arrive.
        XCTAssertEqual(toolResults.count, 2, "both parallel calls must produce a tool result")

        // Sabotage check: swap call1/call2 IDs and the sorted-by-callId
        // lookup below finds the wrong executor result for each callId.
        let byId = Dictionary(uniqueKeysWithValues: toolResults.map { ($0.callId, $0.content) })
        XCTAssertEqual(byId["p-1"], "Cloudy, 15°C", "result for p-1 must come from get_weather")
        XCTAssertEqual(byId["p-2"], "10:30 BST",    "result for p-2 must come from get_time")
    }
}

// MARK: - Private fixtures

/// Minimal executor whose response string is supplied at construction time.
private struct SimpleExecutor: ToolExecutor {
    let definition: ToolDefinition
    private let responseContent: String

    init(name: String, result: String) {
        self.definition = ToolDefinition(
            name: name,
            description: "test fixture",
            parameters: .object(["type": .string("object")])
        )
        self.responseContent = result
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        ToolResult(callId: "", content: responseContent, errorKind: nil)
    }
}

/// Minimal context source that wraps an already-loaded `MockInferenceBackend`.
/// Avoids the package-internal `FakeGenerationContextProvider` defined in
/// `GenerationQueueTests`.
@MainActor
private final class DirectProvider {
    private let _backend: MockInferenceBackend

    init(backend: MockInferenceBackend) {
        _backend = backend
    }

    var currentBackend: (any InferenceBackend)? { _backend }
    var isBackendLoaded: Bool { _backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { .chatML }

    func bind(to queue: GenerationQueue) {
        queue.bindContext(
            currentBackend: { [weak self] in self?._backend },
            isBackendLoaded: { [weak self] in self?._backend.isModelLoaded ?? false },
            selectedPromptTemplate: { .chatML }
        )
    }
}
