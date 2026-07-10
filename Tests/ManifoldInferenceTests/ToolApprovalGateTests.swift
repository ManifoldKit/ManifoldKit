import XCTest
import os
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit tests for ``ToolApprovalGate`` and its interaction with
/// ``GenerationQueue`` at the single-call level.
///
/// These tests exercise just the gate-to-dispatch chokepoint: one tool call
/// per test, so approve/deny paths can be isolated from the broader
/// tool-dispatch loop assertions (iteration caps, repeat short-circuit,
/// byte budgets) covered in ``GenerationQueueToolLoopTests``.
@MainActor
final class ToolApprovalGateTests: XCTestCase {

    // MARK: - Fixtures

    /// Records every call the gate sees so assertions can inspect the
    /// finalized ``ToolCall`` payload. Decision is configurable at
    /// construction time; default is ``ToolApprovalDecision/approved``.
    ///
    /// The recorder uses a simple lock so mutations are safe when the gate
    /// is invoked off the MainActor (today it always is on MainActor, but
    /// the protocol does not require it).
    final class RecordingGate: ToolApprovalGate {
        // OSAllocatedUnfairLock is the async-safe variant; NSLock is not
        // callable from Swift-6 async contexts.
        private let state = OSAllocatedUnfairLock<[ToolCall]>(initialState: [])
        private let decision: ToolApprovalDecision

        init(decision: ToolApprovalDecision = .approved) {
            self.decision = decision
        }

        var observedCalls: [ToolCall] {
            state.withLock { $0 }
        }

        func approve(_ call: ToolCall) async -> ToolApprovalDecision {
            state.withLock { $0.append(call) }
            return decision
        }
    }

    /// Executor that counts invocations so tests can confirm the registry
    /// was (or was not) dispatched through.
    @MainActor
    private final class CountingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        // These tests exist to validate the approval-gate contract, which
        // only fires for tools that opt in via `requiresApproval`. The
        // protocol default is `false` (auto-approve, suitable for read-only
        // tools); explicit override keeps the gate in the dispatch path.
        let requiresApproval: Bool = true
        private(set) var callCount = 0

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "counting")
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await MainActor.run { self.callCount += 1 }
            return ToolResult(callId: "", content: "ok", errorKind: nil)
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

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Builds a coordinator wired for a single tool-call + terminating turn.
    /// The executor emits `c-1` on turn 1, nothing on turn 2 (loop exits).
    private func makeSingleCallSetup(
        gate: any ToolApprovalGate
    ) -> (coordinator: GenerationQueue, executor: CountingExecutor) {
        let executor = CountingExecutor(name: "get_weather")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "get_weather", arguments: #"{"city":"Rome"}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["ok"]]

        let coordinator = GenerationQueue(
            toolRegistry: registry,
            toolApprovalGate: gate
        )
        provider.bind(to: coordinator)
        return (coordinator, executor)
    }

    // MARK: - Approved path

    func test_approvedPath_invokesRegistryDispatch() async throws {
        let gate = RecordingGate(decision: .approved)
        let (coordinator, executor) = makeSingleCallSetup(gate: gate)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "weather?")], config: GenerationConfig(maxOutputTokens: 16))
        _ = try await collectEvents(stream)

        XCTAssertEqual(executor.callCount, 1, "approved path must dispatch through the registry")
        XCTAssertEqual(gate.observedCalls.count, 1, "gate must be consulted once per call")
    }

    // MARK: - Denied path

    func test_deniedPath_skipsRegistryDispatch() async throws {
        let gate = RecordingGate(decision: .denied(reason: "not now"))
        let (coordinator, executor) = makeSingleCallSetup(gate: gate)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "weather?")], config: GenerationConfig(maxOutputTokens: 16))
        _ = try await collectEvents(stream)

        // Sabotage-verify: flipping the `.denied` branch in
        // GenerationQueue to fall through to
        // `result = await toolRegistry!.dispatch(call)` makes callCount == 1
        // and this assertion fails. Verified locally, reverted before commit.
        XCTAssertEqual(executor.callCount, 0, "denied path must NOT reach the registry")
        XCTAssertEqual(gate.observedCalls.count, 1, "gate must still be consulted on deny")
    }

    func test_deniedPath_emitsPermissionDeniedResult() async throws {
        let reason = "the user said no"
        let gate = RecordingGate(decision: .denied(reason: reason))
        let (coordinator, _) = makeSingleCallSetup(gate: gate)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "weather?")], config: GenerationConfig(maxOutputTokens: 16))
        let events = try await collectEvents(stream)

        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        let denied = try XCTUnwrap(results.first, "denial must still surface a ToolResult event")
        XCTAssertEqual(denied.errorKind, .permissionDenied)
        XCTAssertEqual(denied.content, reason)
        XCTAssertEqual(denied.callId, "c-1", "callId must match the original ToolCall")
    }

    func test_deniedPath_withNilReason_usesDefaultString() async throws {
        let gate = RecordingGate(decision: .denied(reason: nil))
        let (coordinator, _) = makeSingleCallSetup(gate: gate)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "weather?")], config: GenerationConfig(maxOutputTokens: 16))
        let events = try await collectEvents(stream)

        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        let denied = try XCTUnwrap(results.first)
        XCTAssertEqual(denied.errorKind, .permissionDenied)
        XCTAssertFalse(denied.content.isEmpty, "default denial string must be non-empty so the model has context")
    }

    // MARK: - Finalized-ToolCall contract

    func test_gateReceivesFinalizedToolCall() async throws {
        // Assert the gate sees a fully-populated call: non-empty toolName,
        // stable id, and complete arguments payload. This pins the
        // finalized-call contract mentioned in the protocol doc.
        let gate = RecordingGate(decision: .approved)
        let (coordinator, _) = makeSingleCallSetup(gate: gate)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "weather?")], config: GenerationConfig(maxOutputTokens: 16))
        _ = try await collectEvents(stream)

        let observed = try XCTUnwrap(gate.observedCalls.first)
        XCTAssertFalse(observed.toolName.isEmpty, "finalized ToolCall must carry a non-empty toolName")
        XCTAssertEqual(observed.id, "c-1", "finalized ToolCall must carry the stable backend-assigned id")
        XCTAssertEqual(observed.arguments, #"{"city":"Rome"}"#, "arguments must be the fully-assembled payload, not a fragment")
    }

    // MARK: - AutoApproveGate default

    func test_autoApproveGate_isDefault_andApproves() async throws {
        // Build a coordinator with no gate override and confirm dispatch
        // still happens — source compat guarantee.
        let executor = CountingExecutor(name: "t")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "t", arguments: "{}")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        let (_, stream) = try coordinator.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "go")], config: GenerationConfig(maxOutputTokens: 8))
        _ = try await collectEvents(stream)

        XCTAssertEqual(executor.callCount, 1, "AutoApproveGate must be the default and approve unconditionally")
    }
}
