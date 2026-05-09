@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Stress test for issue #965 (switch-cancel-resend). Drives N=50 cycles of
/// "send on A → switch to B → resend on B" through `ConversationRuntime` and
/// `InferenceService.discardRequests(notMatching:)` and asserts each cycle
/// persists B's user + assistant turn cleanly with no leakage from A.
///
/// Uses XCTestCase (not Swift Testing) intentionally — `ManifoldRuntimeTests`
/// runs in the same process as the rest of the XCTest batch, and mixing
/// harnesses inside one process triggers a libmalloc SIGABRT (issue #681).
@MainActor
final class SessionDiscardOrderingTests: XCTestCase {

    /// In-memory MessageStore mirror of the fake used by ConversationRuntimeTests.
    /// Re-stated here to keep this file self-contained — these stress tests
    /// drive thousands of writes and benefit from a fixture they own.
    @MainActor
    final class FakeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]
        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
        }
        func updateMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            messages.removeValue(forKey: messageID)
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    private var iterations: Int { 50 }

    func test_switchCancelResend_50cycles_alwaysPersistsSessionB() async throws {
        for cycle in 0..<iterations {
            try await runOneCycle(cycle: cycle)
        }
    }

    private func runOneCycle(cycle: Int) async throws {
        let backend = SlowMockBackend(tokenCount: 30, delayMilliseconds: 20)
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "DiscardStress")
        let store = FakeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference
        )

        let sessionA = UUID()
        let sessionB = UUID()

        // Drain events on a side task so the unbounded buffer doesn't grow
        // unbounded across iterations.
        let drainTask = Task.detached {
            for await _ in runtime.events {}
        }

        // Send on A.
        let aInput = SendInput(sessionID: sessionA, userText: "ask A \(cycle)")
        _ = try await runtime.send(aInput)

        // Wait until A's turn is in-flight (queue reports active or queued).
        let preDeadline = ContinuousClock.now + .milliseconds(500)
        while !inference.isGenerating && ContinuousClock.now < preDeadline {
            await Task.yield()
        }

        // Switch: discardRequests now cancels-and-awaits the active task.
        // We deliberately do NOT call `inference.stopGeneration()` first —
        // the production fix (`switchToSession`) reorders the discard ahead
        // of `resetConversation`/`secureWipe` so that the discard is the
        // single owner of cancel-and-await. Calling stop here would null
        // out `activeTask` and defeat the await; the assertion that this
        // path stays the load-bearing one is part of what this test pins.
        await inference.discardRequests(notMatching: sessionB)
        inference.resetConversation()
        inference.secureWipe()

        // Configure B's reply.
        backend.tokensToYield = ["b0_\(cycle)", " b1_\(cycle)"]
        backend.delayPerToken = .milliseconds(2)

        // Send on B and consume its event stream until completion.
        let bInput = SendInput(sessionID: sessionB, userText: "ask B \(cycle)")
        _ = try await runtime.send(bInput)

        // Poll until B's assistant message is persisted (or fail with diag).
        let bDeadline = ContinuousClock.now + .seconds(3)
        var bAssistantPersisted = false
        while ContinuousClock.now < bDeadline {
            let msgs = try await store.fetchMessages(for: sessionB)
            let asst = msgs.filter { $0.role == .assistant }
            let user = msgs.filter { $0.role == .user }
            if user.count == 1, asst.count == 1, !(asst.first?.content.isEmpty ?? true) {
                bAssistantPersisted = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let bMsgs = try await store.fetchMessages(for: sessionB)
        let bUser = bMsgs.filter { $0.role == .user }
        let bAsst = bMsgs.filter { $0.role == .assistant }
        XCTAssertTrue(bAssistantPersisted, "[cycle \(cycle)] B assistant must persist; got user=\(bUser.count) asst=\(bAsst.count) firstAsst=\(bAsst.first?.content ?? "<nil>")")
        XCTAssertEqual(bUser.count, 1, "[cycle \(cycle)] B should have exactly 1 user message")
        XCTAssertEqual(bAsst.count, 1, "[cycle \(cycle)] B should have exactly 1 assistant message")
        XCTAssertEqual(bAsst.first?.content, "b0_\(cycle) b1_\(cycle)", "[cycle \(cycle)] B assistant content")

        // Leakage check: B must not contain A's tokens.
        for m in bMsgs {
            XCTAssertFalse(m.content.contains("token"), "[cycle \(cycle)] B must not contain A's leftover tokens; got '\(m.content)'")
        }

        drainTask.cancel()
        // Cleanup the backend's loaded state to keep memory bounded.
        backend.unloadModel()
    }
}
