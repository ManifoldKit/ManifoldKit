import XCTest
import os
@testable import ManifoldInference
@testable import ManifoldUI
import ManifoldTestSupport

/// Enforcement tests for #2097: the sticky "approve for the run" semantics
/// (``ManifoldRuntime.ToolApprovalPolicy`` / ``ToolApprovalStickyCache`` /
/// ``ToolApprovalHook``) must reach the engine **through the production
/// ``ToolApprovalGate`` seam** — i.e. via ``UIToolApprovalGate`` under
/// ``UIToolApprovalGate/Policy/askOncePerTool``.
///
/// These run the real orchestrator (`InferenceService` → `GenerationQueue`
/// → `GenerationToolDispatchLoop`) against a scripted `MockInferenceBackend`
/// and prove *behaviour*, not construction:
/// 1. a second dispatch of the same tool is auto-approved without re-prompting
///    the host (the prompt fires exactly once) yet still executes;
/// 2. a denied call never reaches the executor.
///
/// Sabotage-verified while developing: severing the sticky wiring (e.g.
/// dropping `cache.recordApproval` in `ToolApprovalHook.make`, or routing
/// `.askOncePerTool` back through `awaitDecision` without the cache) flips
/// `prompts` to 2 in test 1; both were confirmed to fail then reverted.
@MainActor
final class UIToolApprovalGateStickyEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// Approval-gated executor that counts how many times it actually ran.
    /// `requiresApproval = true` routes every call through the gate (read-only
    /// tools would auto-approve and never exercise the seam). The lock keeps
    /// the counter race-free because `execute` runs off the test's actor —
    /// no `@unchecked Sendable` needed.
    private final class CountingExecutor: ToolExecutor {
        let definition: ToolDefinition
        let requiresApproval = true
        private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        var invocationCount: Int { counter.withLock { $0 } }

        init(name: String) {
            definition = ToolDefinition(name: name, description: "counts invocations")
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            counter.withLock { $0 += 1 }
            return ToolResult(callId: "", content: "ok", errorKind: nil)
        }
    }

    /// Stream-drain completion flag so the resolver loop can stop without a
    /// mutable-capture data race. MainActor-isolated → implicitly Sendable.
    @MainActor
    private final class DrainCompletion {
        var finished = false
    }

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

    private func makeCall(id: String, name: String, arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    // MARK: - Test 1: sticky approval reaches production, prompts once

    func test_stickyApproval_reachesEngine_promptsOnce_executesBothCalls() async throws {
        let backend = makeToolCapableBackend()
        // Two rounds each call the SAME tool with different arguments (so the
        // duplicate-call short-circuit doesn't fire), then a quiet finishing
        // round that emits the visible token.
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-1", name: "search", arguments: #"{"q":"a"}"#)],
            [makeCall(id: "c-2", name: "search", arguments: #"{"q":"b"}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], ["done"]]

        let executor = CountingExecutor(name: "search")
        let registry = ToolRegistry()
        registry.register(executor)

        let gate = UIToolApprovalGate(policy: .askOncePerTool)
        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry,
            toolApprovalGate: gate
        )

        let (_, stream) = try await inference.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            maxOutputTokens: 32,
            tools: [executor.definition],
            maxToolIterations: 5
        )

        // The gate suspends on the FIRST call's approval prompt, so the stream
        // can only drain if we resolve concurrently on the main actor.
        let completion = DrainCompletion()
        let drain = Task { @MainActor in
            var events: [GenerationEvent] = []
            for try await event in stream.events { events.append(event) }
            completion.finished = true
            return events
        }

        // Resolve every host prompt that appears, counting them. If the sticky
        // cache works, the second same-tool call never enqueues a prompt →
        // exactly one resolve. If the wiring is severed, the second call parks
        // a fresh prompt → this loop resolves it too and `prompts` becomes 2
        // (caught by the assertion) rather than hanging.
        var prompts = 0
        let deadline = Date() + 5.0
        while !completion.finished, Date() < deadline {
            if let pending = gate.pending.first {
                gate.resolve(callId: pending.id, with: .approved)
                prompts += 1
            }
            await Task.yield()
        }

        let events = try await drain.value

        XCTAssertEqual(
            prompts, 1,
            "sticky approval must prompt the host exactly once for repeated calls to the same tool"
        )
        XCTAssertEqual(
            executor.invocationCount, 2,
            "both same-tool calls must execute after the single approval"
        )

        // The loop ran to completion — the follow-up visible token flowed.
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokens.joined(), "done", "generation must continue past the sticky-approved calls")
    }

    // MARK: - Test 2: denial blocks execution

    func test_denial_blocksExecutor_executorNeverRuns() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "d-1", name: "search", arguments: #"{"q":"x"}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["blocked"]]

        let executor = CountingExecutor(name: "search")
        let registry = ToolRegistry()
        registry.register(executor)

        let gate = UIToolApprovalGate(policy: .askOncePerTool)
        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry,
            toolApprovalGate: gate
        )

        let (_, stream) = try await inference.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            maxOutputTokens: 32,
            tools: [executor.definition],
            maxToolIterations: 5
        )

        let completion = DrainCompletion()
        let drain = Task { @MainActor in
            var events: [GenerationEvent] = []
            for try await event in stream.events { events.append(event) }
            completion.finished = true
            return events
        }

        // Deny every prompt. A decline is not cached, so a broken wiring would
        // still be denied here — the assertion below is on executor reach.
        let deadline = Date() + 5.0
        while !completion.finished, Date() < deadline {
            if let pending = gate.pending.first {
                gate.resolve(callId: pending.id, with: .denied(reason: "user blocked"))
            }
            await Task.yield()
        }

        let events = try await drain.value

        XCTAssertEqual(
            executor.invocationCount, 0,
            "a denied tool call must never reach the executor"
        )

        // The denial is surfaced to the model as a permissionDenied result and
        // the stream continues (not cancelled).
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 1, "exactly one synthesised result for the denied call")
        XCTAssertEqual(
            results.first?.errorKind, .permissionDenied,
            "denial must synthesise a permissionDenied ToolResult"
        )
    }
}
