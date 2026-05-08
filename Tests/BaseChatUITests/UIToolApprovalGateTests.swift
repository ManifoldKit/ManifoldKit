import XCTest
import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatUI

/// Behavioural tests for ``UIToolApprovalGate``. These exercise the policy
/// matrix (alwaysAsk / askOncePerSession / autoApprove), the session-reset
/// boundary, and the continuation-based resolve hand-off the view layer
/// uses to drive the approval sheet.
@MainActor
final class UIToolApprovalGateTests: XCTestCase {

    // MARK: - Fixtures

    private func call(id: String = "c1", name: String = "sample_repo_search") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: "{}")
    }

    /// Kicks off `gate.approve(call)` on the main actor and returns the in-
    /// flight task. Keeping the approve call inside an explicit Task makes the
    /// actor isolation visible in the test and sidesteps the data-race
    /// diagnostics `async let` would raise when bridging MainActor state.
    private func startApprove(
        _ gate: UIToolApprovalGate,
        _ call: ToolCall
    ) -> Task<ToolApprovalDecision, Never> {
        Task { @MainActor in
            await gate.approve(call)
        }
    }

    /// Spin until the gate's `pending` queue has at least one entry or the
    /// deadline elapses. `approve` appends synchronously on MainActor before
    /// suspending, so a single `Task.yield()` loop is sufficient — the
    /// deadline exists so a regression (e.g. append-after-suspend) fails loud
    /// instead of hanging the test bed.
    private func waitForPending(_ gate: UIToolApprovalGate, deadline: Date = .now + 1.0) async {
        while gate.pending.isEmpty, Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - Policy: autoApprove

    func test_autoApprove_returnsImmediately_withoutEnqueuing() async {
        let gate = UIToolApprovalGate(policy: .autoApprove)

        let decision = await gate.approve(call())
        XCTAssertEqual(decision, .approved)
        XCTAssertTrue(gate.pending.isEmpty, "autoApprove must not enqueue anything")
    }

    // MARK: - Policy: askOncePerSession

    func test_askOncePerSession_secondCallSkipsPrompt() async throws {
        let gate = UIToolApprovalGate(policy: .askOncePerSession)

        let first = startApprove(gate, call(id: "c1"))
        await waitForPending(gate)
        gate.resolve(callId: "c1", with: .approved)
        let firstDecision = await first.value
        XCTAssertEqual(firstDecision, .approved)

        // Second call must skip the queue entirely thanks to the latch.
        // `withTimeout` turns a latch regression into a deterministic 1 s
        // failure rather than a hang: if `hasApprovedThisSession` is not set,
        // approve() would enqueue and await a resolver that never comes —
        // the bounded deadline surfaces that as `TimeoutError` instead.
        let secondCall = call(id: "c2")
        let secondResult = try await withTimeout(.seconds(1)) { @MainActor in
            await gate.approve(secondCall)
        }
        XCTAssertEqual(secondResult, .approved)
        XCTAssertTrue(gate.pending.isEmpty)
    }

    // MARK: - Session-reset boundary

    func test_resetForNewSession_reopensPrompting() async {
        let gate = UIToolApprovalGate(policy: .askOncePerSession)

        let first = startApprove(gate, call(id: "c1"))
        await waitForPending(gate)
        gate.resolve(callId: "c1", with: .approved)
        _ = await first.value

        gate.resetForNewSession()

        let second = startApprove(gate, call(id: "c2"))
        await waitForPending(gate)
        XCTAssertEqual(gate.pending.first?.id, "c2", "Reset must re-arm the queue")

        gate.resolve(callId: "c2", with: .approved)
        _ = await second.value
    }

    // MARK: - Policy: alwaysAsk

    func test_alwaysAsk_queuesEveryCall() async {
        let gate = UIToolApprovalGate(policy: .alwaysAsk)

        let first = startApprove(gate, call(id: "c1"))
        await waitForPending(gate)
        gate.resolve(callId: "c1", with: .approved)
        _ = await first.value

        let second = startApprove(gate, call(id: "c2"))
        await waitForPending(gate)
        XCTAssertEqual(gate.pending.first?.id, "c2", "alwaysAsk must queue every call")
        gate.resolve(callId: "c2", with: .approved)
        _ = await second.value
    }

    // MARK: - Deny reason

    func test_denyCarriesReason() async {
        let gate = UIToolApprovalGate(policy: .alwaysAsk)

        let task = startApprove(gate, call(id: "c1"))
        await waitForPending(gate)
        gate.resolve(callId: "c1", with: .denied(reason: "no"))
        let result = await task.value
        XCTAssertEqual(result, .denied(reason: "no"))
    }

    // MARK: - Observability

    func test_pendingObservableChanges() async {
        let gate = UIToolApprovalGate(policy: .alwaysAsk)
        XCTAssertTrue(gate.pending.isEmpty)

        let task = startApprove(gate, call(id: "obs-1"))
        await waitForPending(gate)
        XCTAssertEqual(gate.pending.count, 1)
        XCTAssertEqual(gate.pending.first?.id, "obs-1")

        gate.resolve(callId: "obs-1", with: .approved)
        _ = await task.value
        XCTAssertTrue(gate.pending.isEmpty, "Resolving must drain the queue")
    }

    // MARK: - Reset drains in-flight continuations

    func test_resetForNewSession_deniesInFlightRequests() async {
        let gate = UIToolApprovalGate(policy: .alwaysAsk)

        let task = startApprove(gate, call(id: "leak"))
        await waitForPending(gate)

        gate.resetForNewSession()

        let result = await task.value
        // Reset must not leak the continuation. The task is resumed with a
        // denial so the generation coordinator sees a structured failure
        // rather than hanging forever.
        guard case .denied = result else {
            XCTFail("Reset should resume in-flight continuations with .denied")
            return
        }
    }
}
