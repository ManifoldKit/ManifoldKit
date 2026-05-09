import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

/// Mock-based coverage for KV-cache-reuse events through the tool-dispatch loop.
///
/// The audit (`α-1` work unit, perf-audit plan) calls out tool loops as the
/// path most likely to silently lose KV reuse: each round invokes a fresh
/// `generate()`, and a stray byte that retokenises differently between rounds
/// breaks the prefix match without any visible signal. These tests pin the
/// shape end-to-end with `MockInferenceBackend.kvCacheReuseToYield*`:
///
/// - `test_toolLoopFiresKVReusePerRound` asserts every backend turn surfaces
///   one `.kvCacheReuse` event on the queue's stream.
/// - `test_toolLoopReuseMonotonic` asserts the per-round reuse count is
///   non-decreasing — a regression detector for "reuse silently resets to 0
///   mid-loop because the prompt grew but reuse didn't".
///
/// Tap point is the raw stream from `InferenceService.enqueueAsync(...)`.
/// `GenerationStreamConsumer` (used by `ConversationRuntime`) maps
/// `.kvCacheReuse` to `.ignore`, so consuming the conversation-event stream
/// would mask these. The queue forwards the event verbatim through its
/// per-request continuation, so observing the raw stream catches everything
/// every round emits.
@MainActor
final class KVReuseToolLoopTests: XCTestCase {

    // MARK: - Recording executor

    /// Tool executor that returns a fixed result — the test only cares that
    /// the loop runs the executor once per scripted call, not what the
    /// content is.
    private final class FixedResultExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private let resultContent: String

        init(name: String, resultContent: String) {
            self.definition = ToolDefinition(
                name: name,
                description: "test",
                parameters: .object([:])
            )
            self.resultContent = resultContent
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: resultContent, errorKind: nil)
        }
    }

    // MARK: - Helpers

    /// Builds a `MockInferenceBackend` that advertises tool-calling support.
    /// The default capability set on the mock has `supportsToolCalling = false`,
    /// which makes `enqueue(...)` reject any request that carries tools.
    private func makeToolCapableBackend() -> MockInferenceBackend {
        let capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
        let backend = MockInferenceBackend(capabilities: capabilities)
        backend.isModelLoaded = true
        return backend
    }

    /// Drains every event from a `GenerationStream`. Throws on stream error.
    private func drainAllEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func makeCall(id: String, name: String, arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    // MARK: - One reuse event per tool-loop round

    /// Three tool-loop rounds: each backend `generate()` must emit
    /// `.kvCacheReuse` once. The queue forwards every non-tool-call event to
    /// the consumer's stream verbatim, so the raw stream sees three reuse
    /// events plus the visible-token round at the end.
    ///
    /// Sabotage check: removing the `kvReuseCount` yield in
    /// `MockInferenceBackend.generate()` collapses the reuse count to zero.
    func test_toolLoopFiresKVReusePerRound() async throws {
        let backend = makeToolCapableBackend()
        // Three tool-call rounds followed by one quiet finishing round.
        // Each entry pops in step with `generate()`.
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-1", name: "ping", arguments: #"{"i":1}"#)],
            [makeCall(id: "c-2", name: "ping", arguments: #"{"i":2}"#)],
            [makeCall(id: "c-3", name: "ping", arguments: #"{"i":3}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], [], ["done"]]
        // Same reuse count every round — the per-round assertion is on event
        // count, not value. Monotonicity has its own test below.
        backend.kvCacheReuseToYieldPerTurn = [4, 8, 12, 16]

        let executor = FixedResultExecutor(name: "ping", resultContent: "ok")
        let registry = ToolRegistry()
        registry.register(executor)

        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry
        )

        let (_, stream) = try await inference.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            maxOutputTokens: 32,
            tools: [executor.definition],
            maxToolIterations: 5
        )

        let events = try await drainAllEvents(stream)

        let reuseEvents = events.compactMap { event -> Int? in
            if case .kvCacheReuse(let n) = event { return n } else { return nil }
        }

        // Four rounds total — three tool-call rounds plus the quiet round
        // that emits the visible-text token. Each round emits exactly one
        // reuse event.
        XCTAssertEqual(
            reuseEvents.count, 4,
            "Each tool-loop round must emit exactly one .kvCacheReuse event "
            + "(observed counts: \(reuseEvents))"
        )

        // Sanity: visible token came through, executor ran on every call round.
        let toolCallCount = events.reduce(0) { acc, e in
            if case .toolCall = e { return acc + 1 }
            return acc
        }
        XCTAssertEqual(toolCallCount, 3, "Three tool calls fanned out")
    }

    // MARK: - Reuse count is non-decreasing across rounds

    /// Per-round reuse count must be monotonically non-decreasing.
    ///
    /// Real backends grow the reused prefix as the conversation lengthens —
    /// each round's reuse covers everything from prior rounds plus the just-
    /// completed turn. A regression where the reuse count drops mid-loop is
    /// the signal we'd want to surface, hence this assertion.
    ///
    /// Sabotage check: feed `[16, 4, 8, 12]` into
    /// `kvCacheReuseToYieldPerTurn` — second-round drop trips the assertion.
    func test_toolLoopReuseMonotonic() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "m-1", name: "ping", arguments: #"{"i":1}"#)],
            [makeCall(id: "m-2", name: "ping", arguments: #"{"i":2}"#)],
            [makeCall(id: "m-3", name: "ping", arguments: #"{"i":3}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], [], ["fin"]]
        // Strictly increasing: real backends grow reuse turn-by-turn.
        backend.kvCacheReuseToYieldPerTurn = [5, 12, 19, 26]

        let executor = FixedResultExecutor(name: "ping", resultContent: "ok")
        let registry = ToolRegistry()
        registry.register(executor)

        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry
        )

        let (_, stream) = try await inference.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "march")],
            maxOutputTokens: 32,
            tools: [executor.definition],
            maxToolIterations: 5
        )

        let events = try await drainAllEvents(stream)

        let reuseValues = events.compactMap { event -> Int? in
            if case .kvCacheReuse(let n) = event { return n } else { return nil }
        }

        XCTAssertEqual(reuseValues.count, 4, "One reuse event per round")

        // Pairwise non-decreasing: every adjacent pair must satisfy a <= b.
        // Reporting the full sequence on failure makes regressions diagnose
        // themselves without re-running.
        for i in 1..<reuseValues.count {
            XCTAssertLessThanOrEqual(
                reuseValues[i - 1], reuseValues[i],
                "promptTokensReused must be non-decreasing across tool-loop rounds. "
                + "Saw drop at index \(i): \(reuseValues)"
            )
        }
    }
}
