@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration coverage for the inert-code-audit finding 1 fix
/// (`docs/plans/inert-code-audit-2026-07.md`, finding 1): `TranscriptHealer`
/// must run on the real turn loop (`ConversationTurnExecutor
/// .fetchAndPrepareTurnHistory`), not just the UI's cosmetic reload path
/// (`SessionController.loadMessages`).
///
/// Reproduces the #629 shape: a session whose history ends with an assistant
/// `tool_use` that never received a matching `tool_result` (the process was
/// killed — or the turn cancelled — mid-tool; cancellation persists the
/// orphan call as a normal non-crash outcome). Drives a real turn through
/// `ConversationRuntime` with an
/// in-memory `MessageStore` (never a mock persistence layer — CLAUDE.md) and
/// `MockInferenceBackend`, then asserts the structured history the backend
/// actually received contains a synthesised terminal `ToolResult` for the
/// orphaned call. Without the fix, the orphan `toolCall` part reaches the
/// backend with no matching result — exactly the shape a real cloud API
/// rejects.
@MainActor
final class TranscriptHealerLiveTurnPathTests: XCTestCase {
    private enum TestError: Error {
        case timeout
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration = .seconds(10),
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TestError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func makeRuntime(
        store: InMemoryMessageStore,
        mock: MockInferenceBackend
    ) -> ConversationRuntime {
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        return ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            pipeline: nil,
            generationHooks: [],
            compressionPolicy: nil
        )
    }

    func test_sendTurn_healsOrphanToolCallBeforeReachingBackend() async throws {
        let store = InMemoryMessageStore()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["got it"]

        let sessionID = UUID()
        let base = Date()
        let orphanCallID = "orphan-call-\(UUID().uuidString)"
        let orphanCall = ToolCall(
            id: orphanCallID,
            toolName: "search",
            arguments: "{\"q\":\"golden gate bridge\"}"
        )

        // The #629 shape: the process was killed after the model emitted the
        // tool call but before the executor's result was persisted, so no
        // `.toolResult` for `orphanCallID` exists anywhere in the transcript.
        let userTurn = ChatMessage(
            role: .user,
            content: "Look up the bridge for me",
            timestamp: base,
            sessionID: sessionID
        )
        let assistantTurnWithOrphanCall = ChatMessage(
            role: .assistant,
            contentParts: [.text("Let me check."), .toolCall(orphanCall)],
            timestamp: base.addingTimeInterval(1),
            sessionID: sessionID
        )
        try await store.insertMessage(userTurn)
        try await store.insertMessage(assistantTurnWithOrphanCall)

        let runtime = makeRuntime(store: store, mock: mock)

        // Next turn on session reload — the shape #629 describes: the host
        // sends a follow-up user message without ever having healed the
        // orphan call first.
        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Any update?", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcome = try await withTimeout { await handle.outcome }
        XCTAssertNil(outcome.error, "Turn should complete cleanly once the orphan call is healed")

        let sentParts = (mock.lastReceivedStructuredHistory ?? []).flatMap(\.parts)
        let sentToolResults: [ToolResult] = sentParts.compactMap {
            if case .toolResult(let result) = $0 { return result }
            return nil
        }

        let synthesised = sentToolResults.first { $0.callId == orphanCallID }
        XCTAssertNotNil(
            synthesised,
            "The backend must receive a synthesised ToolResult for the orphan call; " +
            "otherwise the next request reproduces #629's 'missing tool_result' rejection."
        )
        XCTAssertEqual(synthesised?.errorKind, .cancelled)

        // The synthesised result must land in the *same* structured message as
        // the orphan call (TranscriptHealer's contract) so message-granularity
        // trimming downstream can never re-split a call from its result.
        let assistantMessage = mock.lastReceivedStructuredHistory?.first { message in
            message.parts.contains { part in
                if case .toolCall(let call) = part { return call.id == orphanCallID }
                return false
            }
        }
        XCTAssertNotNil(assistantMessage)
        XCTAssertTrue(
            assistantMessage?.parts.contains(where: {
                if case .toolResult(let result) = $0 { return result.callId == orphanCallID }
                return false
            }) ?? false
        )

        // The original persisted record is untouched — healing only affects
        // what's sent to the backend, not what's stored.
        let persisted = try await store.fetchMessages(for: sessionID)
        let persistedAssistant = try XCTUnwrap(
            persisted.first { $0.id == assistantTurnWithOrphanCall.id }
        )
        XCTAssertFalse(
            persistedAssistant.contentParts.contains(where: {
                if case .toolResult = $0 { return true }
                return false
            }),
            "Healing must not mutate persistence — only the prompt-visible history sent to the backend"
        )
    }

    // MARK: - Pre-turn compression path (review round 1)

    /// Captures the history `TurnCompressionCoordinator` hands to the
    /// pre-turn policy — whose `generate` closure drives a real backend call —
    /// so the test can prove that generation-bound fetch was healed too.
    actor CapturingPreTurnPolicy: PreTurnCompressionPolicy {
        private var receivedHistory: [ChatMessage]?

        func snapshotReceivedHistory() -> [ChatMessage]? {
            receivedHistory
        }

        nonisolated func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
            true
        }

        func compressBeforeTurn(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            receivedHistory = history
            return history
        }
    }

    func test_preTurnCompression_receivesHealedHistory() async throws {
        let store = InMemoryMessageStore()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true

        let sessionID = UUID()
        let orphanCallID = "orphan-compress-\(UUID().uuidString)"
        let orphanCall = ToolCall(
            id: orphanCallID,
            toolName: "search",
            arguments: "{\"q\":\"tides\"}"
        )
        try await store.insertMessage(ChatMessage(
            role: .user,
            content: "Check the tides",
            timestamp: Date(),
            sessionID: sessionID
        ))
        try await store.insertMessage(ChatMessage(
            role: .assistant,
            contentParts: [.toolCall(orphanCall)],
            timestamp: Date().addingTimeInterval(1),
            sessionID: sessionID
        ))

        let policy = CapturingPreTurnPolicy()
        let inference = InferenceService(backend: mock, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            pipeline: nil,
            generationHooks: [],
            compressionPolicy: nil,
            preTurnCompressionPolicy: policy
        )

        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Any update?", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcome = try await withTimeout { await handle.outcome }
        XCTAssertNil(outcome.error)

        let capturedHistory = await policy.snapshotReceivedHistory()
        let received = try XCTUnwrap(capturedHistory)
        let assistantMessage = received.first { message in
            message.contentParts.contains { part in
                if case .toolCall(let call) = part { return call.id == orphanCallID }
                return false
            }
        }
        XCTAssertNotNil(assistantMessage)
        let synthesised: ToolResult? = assistantMessage?.contentParts.compactMap {
            if case .toolResult(let result) = $0, result.callId == orphanCallID { return result }
            return nil
        }.first
        XCTAssertNotNil(
            synthesised,
            "Pre-turn compression's generation-bound history must arrive healed — " +
            "the policy's generate closure sends it to a real backend (#629)."
        )
        XCTAssertEqual(synthesised?.errorKind, .cancelled)
    }
}
