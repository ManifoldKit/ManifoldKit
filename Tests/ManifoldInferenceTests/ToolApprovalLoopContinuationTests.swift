import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Dispatch-loop contract for sticky tool-approval (#1923 Part 1): a declined
/// tool call (which the `ToolApprovalHook` factory in `ManifoldRuntime` maps to
/// `PreToolUseOutcome.block`) must surface a typed `permissionDenied`
/// `ToolResult` AND let the turn loop continue to the next turn — it must not
/// abort generation.
///
/// The factory itself lives in `ManifoldRuntime` (which this Inference-layer
/// test target cannot import); here we install the same `.block` outcome the
/// factory produces on a decline and assert the loop keeps turning. The
/// policy→outcome mapping is covered in `ManifoldRuntimeTests`.
@MainActor
final class ToolApprovalLoopContinuationTests: XCTestCase {

    @MainActor
    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private(set) var callCount = 0

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "test", parameters: .object([:]))
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await MainActor.run { self.callCount += 1 }
            return ToolResult(callId: "", content: "should-not-run")
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

    /// A declined (blocked) call feeds a typed `permissionDenied` result back
    /// to the model and the loop terminates **normally** (`.stop`) rather than
    /// aborting/erroring/cancelling. Proves the decline path keeps the loop
    /// well-formed.
    ///
    /// Note: when *every* tool call in a turn is blocked, nothing is dispatched,
    /// so the loop has no result to feed into a further generation and stops
    /// after this turn — but it stops cleanly via `.stop`, not an abort. (When
    /// a turn mixes approved + declined calls, the approved dispatches keep the
    /// loop turning; that is the existing dispatch-loop behaviour.)
    func test_declinedCall_feedsPermissionDeniedAndLoopContinues() async throws {
        let executor = RecordingExecutor(name: "danger")
        let registry = ToolRegistry()
        registry.register(executor)

        // Turn 1: model emits a tool call (which the host will decline).
        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "d-1", toolName: "danger", arguments: "{}")],
        ]
        provider.backend.tokensToYieldPerTurn = [[]]

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        // Decline → `.block`, exactly what `ToolApprovalHook.make` returns when
        // the host approve prompt returns `false`.
        coordinator.preToolUseHook = { @Sendable _, _, _ in
            .block(reason: "Tool call declined by the user.")
        }

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "do the dangerous thing")],
            maxOutputTokens: 16
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        // The declined tool never executed.
        XCTAssertEqual(executor.callCount, 0, "a declined call must not invoke the executor")

        // A typed permission-denied result reached the model.
        let denied = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event, r.callId == "d-1" { return r }
            return nil
        }
        XCTAssertEqual(denied.count, 1, "the declined call must surface exactly one result")
        XCTAssertEqual(denied.first?.errorKind, .permissionDenied, "the declined result must be typed permissionDenied")

        // The loop did NOT abort: it terminated normally with `.stop`. A
        // cancelled/errored loop would not emit a terminal `.stop`.
        let completions = events.compactMap { event -> GenerationCompletion? in
            if case .generationCompleted(let c) = event { return c } else { return nil }
        }
        XCTAssertEqual(completions.last?.reason, .stop, "generation must complete with .stop, proving the denial did not abort the loop")
    }
}
