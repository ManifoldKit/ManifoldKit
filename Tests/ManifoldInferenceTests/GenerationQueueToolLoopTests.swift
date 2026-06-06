import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit tests for the tool-dispatch loop inside `GenerationQueue`.
///
/// Coverage:
/// - end-to-end dispatch: model emits a tool call, registry dispatches,
///   `.toolResult` surfaces on the stream, next turn is invoked with the
///   result threaded through tool-aware history
/// - iteration cap: after `maxToolIterations` tool calls the loop stops and
///   emits `.toolIterationLimitExceeded(iterations:)`
/// - repeat-call short-circuit: identical `(name, args)` twice in a row
///   bypasses the executor
/// - byte-budget guard: a tool that returns huge content terminates the loop
///   with a synthesised `.permanent` result
@MainActor
final class GenerationQueueToolLoopTests: XCTestCase {

    // MARK: - Fixtures

    /// Tool executor that records each call so tests can assert on invocation
    /// count and last-seen arguments. `@MainActor` so counters can be
    /// mutated from `execute(arguments:)` without lock-in-async ceremony —
    /// the coordinator itself is `@MainActor` isolated so dispatch hops to
    /// this actor anyway.
    @MainActor
    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private let handler: @Sendable (JSONSchemaValue) async throws -> ToolResult

        private(set) var callCount = 0
        private(set) var lastArguments: JSONSchemaValue?

        init(
            name: String,
            schema: JSONSchemaValue = .object([:]),
            handler: @escaping @Sendable (JSONSchemaValue) async throws -> ToolResult
        ) {
            self.definition = ToolDefinition(name: name, description: "test", parameters: schema)
            self.handler = handler
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await MainActor.run {
                self.callCount += 1
                self.lastArguments = arguments
            }
            return try await handler(arguments)
        }
    }

    private struct StreamingProgressExecutor: ToolExecutor {
        let definition = ToolDefinition(name: "streaming_tool", description: "streaming", parameters: .object([:]))

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: "single-shot path should not run")
        }

        func executeStreaming(arguments: JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.progress(message: "phase 1", fraction: 0.1))
                continuation.yield(.progress(message: "phase 2", fraction: 0.9))
                continuation.yield(.completed(ToolResult(callId: "executor-stale-id", content: "streamed-result")))
                continuation.finish()
            }
        }
    }

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a coordinator with the supplied registry already wired.
    private func makeCoordinator(registry: ToolRegistry) -> GenerationQueue {
        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)
        return coordinator
    }

    /// Drain every event from a streamed generation.
    private func collectEvents(
        _ stream: GenerationStream
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func makeCall(id: String, name: String, arguments: String) -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    // MARK: - Streaming tool-call deltas (#621)

    func test_streamingToolCallDeltas_forwardedThroughCoordinatorStream() async throws {
        // Backend emits start → delta → delta → toolCall in one turn,
        // then a quiet final turn. The coordinator must forward the
        // streaming-delta GenerationEvents verbatim — they are not
        // reasoning/diagnostic events the coordinator should swallow.
        let executor = RecordingExecutor(name: "get_weather") { _ in
            ToolResult(callId: "", content: "sunny", errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)

        let call = makeCall(id: "sd-1", name: "get_weather", arguments: #"{"city":"Rome"}"#)
        provider.backend.scriptedToolCallDeltasPerTurn = [
            [
                .start(callId: "sd-1", name: "get_weather"),
                .delta(callId: "sd-1", textDelta: #"{"city"#),
                .delta(callId: "sd-1", textDelta: #"":"Rome"}"#),
                .call(call),
            ],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["bye"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "weather?")],
            maxOutputTokens: 32
        )

        let events = try await collectEvents(stream)

        let starts = events.compactMap { e -> (String, String)? in
            if case .toolCallStart(let id, let name) = e { return (id, name) }
            return nil
        }
        let deltas = events.compactMap { e -> (String, String)? in
            if case .toolCallArgumentsDelta(let id, let d) = e { return (id, d) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.0, "sd-1")
        XCTAssertEqual(starts.first?.1, "get_weather")
        XCTAssertEqual(deltas.map(\.1), [#"{"city"#, #"":"Rome"}"#])

        // Authoritative call still lands.
        let toolCalls = events.compactMap { e -> ToolCall? in
            if case .toolCall(let c) = e { return c } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "sd-1")
    }

    // MARK: - End-to-end dispatch

    func test_toolCall_dispatchesThroughRegistry_andSurfacesResult() async throws {
        // Turn 1: model emits a tool call. Turn 2: model emits plain visible
        // tokens with no further tool call, terminating the loop.
        let executor = RecordingExecutor(name: "get_weather") { _ in
            ToolResult(callId: "", content: #"{"summary":"sunny"}"#, errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-1", name: "get_weather", arguments: #"{"city":"Rome"}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [
            [],
            ["The weather", " is sunny."],
        ]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "What's the weather in Rome?")],
            maxOutputTokens: 128
        )

        let events = try await collectEvents(stream)

        XCTAssertEqual(executor.callCount, 1, "executor must be invoked exactly once")

        // Sabotage check: removing the `.toolCall`/`.toolResult` yield in
        // `runToolDispatchLoop` leaves `toolCalls` / `toolResults` empty.
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        let toolResults = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.callId, "c-1")
        XCTAssertEqual(toolResults.first?.content, #"{"summary":"sunny"}"#)

        // Second turn must have actually run — visible tokens followed.
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokens.joined(), "The weather is sunny.")
    }

    func test_streamingToolProgress_emitsBetweenDispatchStartedAndToolResult() async throws {
        let registry = ToolRegistry()
        registry.register(StreamingProgressExecutor())

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "p-1", name: "streaming_tool", arguments: "{}")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "run streaming tool")],
            maxOutputTokens: 64
        )

        let events = try await collectEvents(stream)

        let toolCallIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolCall = event { return true }
            return false
        })
        let startedIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolDispatchStarted = event { return true }
            return false
        })
        let progressIndices = events.indices.filter { index in
            if case .toolProgress = events[index] { return true }
            return false
        }
        let resultIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolResult = event { return true }
            return false
        })
        let completedIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolDispatchCompleted = event { return true }
            return false
        })

        XCTAssertEqual(progressIndices.count, 2)
        XCTAssertLessThan(toolCallIndex, startedIndex)
        XCTAssertLessThan(startedIndex, progressIndices[0])
        XCTAssertLessThan(progressIndices[0], progressIndices[1])
        XCTAssertLessThan(progressIndices[1], resultIndex)
        XCTAssertLessThan(resultIndex, completedIndex)

        let progress = progressIndices.compactMap { index -> ToolProgressEvent? in
            if case .toolProgress(let progress) = events[index] { return progress }
            return nil
        }
        XCTAssertEqual(progress.map(\.callId), ["p-1", "p-1"])
        XCTAssertEqual(progress.map(\.name), ["streaming_tool", "streaming_tool"])
        XCTAssertEqual(progress.map(\.message), ["phase 1", "phase 2"])
        XCTAssertEqual(progress[0].fraction, 0.1)
        XCTAssertEqual(progress[1].fraction, 0.9)

        let result = try XCTUnwrap(events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }.first)
        XCTAssertEqual(result.callId, "p-1")
        XCTAssertEqual(result.content, "streamed-result")
    }

    func test_toolCall_threadsResultIntoNextTurnHistory_viaToolCallingHistoryReceiver() async throws {
        // The mock is a ConversationHistoryReceiver but not a
        // ToolCallingHistoryReceiver — exercise that the coordinator still
        // runs a second backend turn carrying the tool result. Use a
        // dedicated tool-aware mock for this assertion.
        let toolAwareBackend = ToolAwareMockBackend()
        toolAwareBackend.isModelLoaded = true
        toolAwareBackend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-a", name: "get_time", arguments: "{}")],
            [],
        ]
        toolAwareBackend.tokensToYieldPerTurn = [[], ["12:00"]]

        let toolAwareProvider = ToolAwareProvider(backend: toolAwareBackend)

        let executor = RecordingExecutor(name: "get_time") { _ in
            ToolResult(callId: "", content: "12:00", errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)

        let coordinator = GenerationQueue(toolRegistry: registry)
        toolAwareProvider.bind(to: coordinator)

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "what time?")],
            maxOutputTokens: 16
        )
        _ = try await collectEvents(stream)

        // The backend recorded the tool-aware history passed for its second
        // turn — must include a `role: "tool"` entry with the call id.
        let history = try XCTUnwrap(toolAwareBackend.receivedToolAwareHistories.last)
        let toolEntry = history.last { $0.role == "tool" }
        XCTAssertNotNil(toolEntry)
        XCTAssertEqual(toolEntry?.toolCallId, "c-a")
        XCTAssertEqual(toolEntry?.content, "12:00")
    }

    // MARK: - Iteration cap

    func test_loopCap_emitsToolLoopLimitReached() async throws {
        // Model emits a distinct tool call on every turn — coordinator must
        // stop at `maxToolIterations` and surface `.toolIterationLimitExceeded`.
        // Arguments vary per turn so the repeat-call short-circuit does not
        // bypass executor invocations.
        let executor = RecordingExecutor(name: "spam") { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = (0..<20).map { idx in
            [makeCall(id: "s-\(idx)", name: "spam", arguments: #"{"i":\#(idx)}"#)]
        }

        let coordinator = makeCoordinator(registry: registry)
        // Low cap (3) so the sabotage check — a deleted iteration guard —
        // flips the observed cap away from exactly 3.
        let (_, stream) = try coordinator.enqueueCustomConfig(
            messages: [("user", "go")],
            config: GenerationConfig(maxOutputTokens: 8, maxToolIterations: 3)
        )
        let events = try await collectEvents(stream)

        let limits = events.compactMap { event -> Int? in
            if case .toolIterationLimitExceeded(let n) = event { return n } else { return nil }
        }
        // Sabotage check: deleting the `iterations > limit` guard in
        // runToolDispatchLoop lets the loop run forever (test times out) or,
        // if the guard is weakened, emits with the wrong count.
        XCTAssertEqual(limits, [3], "cap must match the configured maxToolIterations")
        XCTAssertEqual(executor.callCount, 3, "executor should be called exactly cap times")
    }

    // MARK: - Repeat-call short-circuit

    func test_repeatCall_shortCircuit_doesNotInvokeExecutorSecondTime() async throws {
        let executor = RecordingExecutor(name: "dupe") { _ in
            ToolResult(callId: "", content: "first-result", errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)

        // Same (name, args) twice, then stop. The first call dispatches
        // normally; the second returns a synthesised permanent error without
        // invoking the executor.
        let dupeCall = makeCall(id: "d", name: "dupe", arguments: #"{"q":"x"}"#)
        provider.backend.scriptedToolCallsPerTurn = [
            [dupeCall],
            [ToolCall(id: "d2", toolName: "dupe", arguments: #"{"q":"x"}"#)],
            [],
        ]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 8
        )
        let events = try await collectEvents(stream)

        XCTAssertEqual(executor.callCount, 1, "executor must run only for the first unique call")
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].errorKind, nil)
        XCTAssertEqual(results[1].errorKind, .permanent)
        XCTAssertTrue(
            results[1].content.contains("identical arguments"),
            "short-circuit result must flag the duplicate; got: \(results[1].content)"
        )
    }

    // MARK: - Byte-budget guard

    func test_tokenBudget_exhausted_terminatesLoopWithPermanentResult() async throws {
        // Tool returns 1 MiB of content; the coordinator's budget (512 KiB by
        // design) is exceeded on the first dispatch so the loop terminates
        // after emitting a permanent result.
        let giantContent = String(repeating: "x", count: 1_048_576)
        let executor = RecordingExecutor(name: "giant") { _ in
            ToolResult(callId: "", content: giantContent, errorKind: nil)
        }
        let registry = ToolRegistry()
        // The registry's default `ToolOutputPolicy` (32 KB rejectWithError)
        // would short-circuit the 1 MiB payload at dispatch exit. This test
        // covers the *coordinator's* byte-budget guard, which lives one
        // layer up — opt out of registry enforcement so the giant payload
        // still flows through.
        registry.outputPolicy = ToolOutputPolicy(maxBytes: .max, onOversize: .allow)
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "g1", name: "giant", arguments: "{}")],
            [makeCall(id: "g2", name: "giant", arguments: "{}")],
            [makeCall(id: "g3", name: "giant", arguments: "{}")],
        ]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 8
        )
        let events = try await collectEvents(stream)

        // The first dispatch returns real content (exceeds budget post-hoc);
        // the second iteration is blocked before invocation so the executor
        // runs exactly once.
        XCTAssertEqual(executor.callCount, 1)
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        // Exactly one result — the loop exits right after recording the
        // oversized dispatch (see `toolResultByteTotal >= budget` check).
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.callId, "g1")
    }
}

// MARK: - Test helpers

/// Extension that exposes a raw-config enqueue path for tests that need to
/// set every field on `GenerationConfig` (notably `maxToolIterations`).
@MainActor
extension GenerationQueue {
    func enqueueCustomConfig(
        messages: [(role: String, content: String)],
        config: GenerationConfig,
        priority: GenerationPriority = .normal,
        requestGroupID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        try enqueue(
            messages: messages,
            systemPrompt: nil,
            temperature: config.temperature,
            topP: config.topP,
            repeatPenalty: config.repeatPenalty,
            maxOutputTokens: config.maxOutputTokens,
            maxThinkingTokens: config.maxThinkingTokens,
            jsonMode: config.jsonMode,
            tools: config.tools,
            toolChoice: config.toolChoice,
            maxToolIterations: config.maxToolIterations,
            priority: priority,
            requestGroupID: requestGroupID
        )
    }
}

// MARK: - ToolAwareMockBackend

/// Backend variant that records the tool-aware history for each generate
/// call. Used to assert the coordinator passes structured tool entries to
/// backends that conform to `ToolCallingHistoryReceiver`.
private final class ToolAwareMockBackend: InferenceBackend, ToolCallingHistoryReceiver, ConversationHistoryReceiver, @unchecked Sendable {
    private let lock = NSLock()

    var isModelLoaded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isModelLoaded }
        set { lock.lock(); _isModelLoaded = newValue; lock.unlock() }
    }
    private var _isModelLoaded = false

    var isGenerating: Bool { false }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )

    var scriptedToolCallsPerTurn: [[ToolCall]] {
        get { lock.lock(); defer { lock.unlock() }; return _scriptedToolCallsPerTurn }
        set { lock.lock(); _scriptedToolCallsPerTurn = newValue; lock.unlock() }
    }
    private var _scriptedToolCallsPerTurn: [[ToolCall]] = []

    var tokensToYieldPerTurn: [[String]] {
        get { lock.lock(); defer { lock.unlock() }; return _tokensToYieldPerTurn }
        set { lock.lock(); _tokensToYieldPerTurn = newValue; lock.unlock() }
    }
    private var _tokensToYieldPerTurn: [[String]] = []

    var receivedToolAwareHistories: [[ToolAwareHistoryEntry]] {
        lock.lock(); defer { lock.unlock() }; return _receivedToolAwareHistories
    }
    private var _receivedToolAwareHistories: [[ToolAwareHistoryEntry]] = []

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        lock.lock()
        let tokens = _tokensToYieldPerTurn.isEmpty ? [] : _tokensToYieldPerTurn.removeFirst()
        let calls = _scriptedToolCallsPerTurn.isEmpty ? [] : _scriptedToolCallsPerTurn.removeFirst()
        lock.unlock()
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for token in tokens { continuation.yield(.token(token)) }
                for call in calls { continuation.yield(.toolCall(call)) }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
    func resetConversation() {}

    // MARK: - History hooks

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        // No-op; the tool-aware path is what the test asserts on.
    }

    func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        lock.lock()
        _receivedToolAwareHistories.append(messages)
        lock.unlock()
    }
}

@MainActor
private final class ToolAwareProvider {
    let backend: ToolAwareMockBackend
    init(backend: ToolAwareMockBackend) { self.backend = backend }
    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { .chatML }

    func bind(to queue: GenerationQueue) {
        queue.bindContext(
            currentBackend: { [weak self] in self?.backend },
            isBackendLoaded: { [weak self] in self?.backend.isModelLoaded ?? false },
            selectedPromptTemplate: { .chatML }
        )
    }
}
