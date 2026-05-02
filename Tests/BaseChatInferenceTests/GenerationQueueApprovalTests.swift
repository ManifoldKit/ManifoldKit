import XCTest
import os
@testable import BaseChatInference
import BaseChatTestSupport

/// Integration tests for the ``ToolApprovalGate`` + ``GenerationQueue``
/// interaction at the full-stream level.
///
/// Distinct from ``ToolApprovalGateTests`` in that these exercise stream
/// continuation behaviour — specifically that a denial does NOT cancel the
/// active request, the coordinator proceeds to the model's next turn, and
/// the synthesised ``ToolResult`` flows through as a normal event.
@MainActor
final class GenerationQueueApprovalTests: XCTestCase {

    // MARK: - Fixtures

    private final class FixedGate: ToolApprovalGate, @unchecked Sendable {
        let decision: ToolApprovalDecision
        init(_ decision: ToolApprovalDecision) { self.decision = decision }
        func approve(_ call: ToolCall) async -> ToolApprovalDecision { decision }
    }

    /// Dummy executor — asserts it is never reached on the deny path.
    @MainActor
    private final class FailIfInvokedExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        // Opt in to the approval-gate path. Default is `false` (auto-approve
        // for read-only tools), which would short-circuit the gate and break
        // these tests' purpose of exercising gate semantics.
        let requiresApproval: Bool = true
        private(set) var wasInvoked = false
        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "should not run")
        }
        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await MainActor.run { self.wasInvoked = true }
            return ToolResult(callId: "", content: "UNEXPECTED", errorKind: nil)
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

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Deny path — synthesised ToolResult

    func test_denyPath_synthesisesPermissionDeniedResult_andStreamContinues() async throws {
        // Turn 1: model emits a single tool call. Turn 2: model emits plain
        // text and the loop exits. The gate denies the call so no executor
        // runs, a `.permissionDenied` ToolResult is synthesised, and the
        // coordinator must still run turn 2 (assertions on the follow-up
        // tokens would not be observable if the stream was cancelled).
        let executor = FailIfInvokedExecutor(name: "get_weather")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "get_weather", arguments: #"{"city":"Rome"}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [
            [],
            ["I", " cannot", " check", " the", " weather."],
        ]

        let coordinator = GenerationQueue(
            toolRegistry: registry,
            toolApprovalGate: FixedGate(.denied(reason: "user blocked this tool"))
        )
        coordinator.provider = provider

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "weather in Rome?")],
            maxOutputTokens: 64
        )
        let events = try await collectEvents(stream)

        // Executor must NOT have been hit.
        XCTAssertFalse(executor.wasInvoked, "deny path must short-circuit before the registry")

        // Exactly one synthesised ToolResult with .permissionDenied.
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.errorKind, .permissionDenied)
        XCTAssertEqual(results.first?.callId, "c-1")
        XCTAssertEqual(results.first?.content, "user blocked this tool")

        // Model continued past the denial: turn 2's visible tokens must have
        // flowed through the stream, proving it wasn't cancelled.
        // Sabotage-verify: deleting the `self.continuations[...].yield(.toolResult(result))`
        // emission in GenerationQueue.runToolDispatchLoop empties the
        // `results` array above and this test fails. Verified, reverted.
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(
            tokens.joined(),
            "I cannot check the weather.",
            "stream must continue to the next turn after a denial"
        )
    }

    func test_denyPath_streamTerminatesCleanly_noError() async throws {
        // Stream must complete via a normal `.done` phase, not `.failed`.
        let executor = FailIfInvokedExecutor(name: "go")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "go", arguments: "{}")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]

        let coordinator = GenerationQueue(
            toolRegistry: registry,
            toolApprovalGate: FixedGate(.denied(reason: nil))
        )
        coordinator.provider = provider

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 8
        )
        _ = try await collectEvents(stream)

        // `.done` is the terminal phase for a successfully-completed run.
        // `.failed(...)` would indicate the denial cancelled the stream,
        // which is explicitly NOT what the coordinator does.
        XCTAssertEqual(stream.phase, .done, "deny must not fail the stream; got \(stream.phase)")
    }

    // MARK: - Multiple tool calls within one request

    func test_denyThenApprove_eachCallGoesThroughGate() async throws {
        // Two sequential tool calls (different arguments so no repeat
        // short-circuit). Gate denies both — the second call must still hit
        // the gate, proving the gate is consulted per-call and not cached.
        let executor = FailIfInvokedExecutor(name: "query")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "query", arguments: #"{"q":"a"}"#)],
            [ToolCall(id: "c-2", toolName: "query", arguments: #"{"q":"b"}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], [], ["ok"]]

        final class CountingGate: ToolApprovalGate {
            private let state = OSAllocatedUnfairLock<Int>(initialState: 0)
            var count: Int { state.withLock { $0 } }
            func approve(_ call: ToolCall) async -> ToolApprovalDecision {
                state.withLock { $0 += 1 }
                return .denied(reason: "no")
            }
        }
        let gate = CountingGate()

        let coordinator = GenerationQueue(
            toolRegistry: registry,
            toolApprovalGate: gate
        )
        coordinator.provider = provider

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 8
        )
        _ = try await collectEvents(stream)

        XCTAssertEqual(gate.count, 2, "gate must be consulted for every tool call, including denied ones")
        XCTAssertFalse(executor.wasInvoked)
    }
}
