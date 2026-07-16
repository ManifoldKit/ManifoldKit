@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that a thinking-only turn — the model emits reasoning tokens but
/// no visible text and no tool calls — persists the assistant message with
/// its finalized ``MessagePart/thinking(_:signature:)`` content part, rather
/// than being silently dropped by the empty-response gate.
///
/// Before this fix, ``GenerationStreamAccumulator/isEmptyResponse`` only
/// tracked visible tokens, so `ConversationTurnExecutor` treated a
/// thinking-only stream identically to a truly empty one and discarded the
/// whole message (`ConversationTurnExecutor.swift` around the
/// `accumulator.isEmptyResponse && !hasToolContent` gate). See the stacked
/// base PR that makes thinking content parts persist in the first place.
@MainActor
final class ThinkingOnlyTurnPersistenceTests: XCTestCase {

    @MainActor
    final class FakeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }
        func updateMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            messages.removeValue(forKey: messageID)
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    func test_thinkingOnlyTurn_persistsAssistantMessage_withThinkingPart() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []                         // no visible text
        backend.thinkingTokensToYield = ["Let me consider this carefully."]

        let inference = InferenceService(backend: backend, name: "ThinkingOnlyBackend")
        let store = FakeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            pipeline: nil
        )

        let drain = Task.detached { [runtime] in
            for await event in runtime.events {
                if case .streamFinished = event { return }
            }
        }

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(sessionID: sessionID, kind: .send(text: "think about it")))
        try await wait(for: drain)

        let persisted = try await store.fetchMessages(for: sessionID)
        let assistantMessages = persisted.filter { $0.role == .assistant }

        XCTAssertEqual(
            assistantMessages.count, 1,
            "A thinking-only turn must persist exactly one assistant message, not be dropped as empty"
        )

        let thinkingParts = assistantMessages.first?.contentParts.compactMap { part -> String? in
            if case .thinking(let text, _) = part { return text }
            return nil
        } ?? []

        XCTAssertEqual(
            thinkingParts, ["Let me consider this carefully."],
            "The persisted assistant message must carry the finalized thinking content part"
        )
    }

    private func wait(for task: Task<Void, Never>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                task.cancel()
                throw TestError.deadlineElapsed
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private enum TestError: Error {
        case deadlineElapsed
    }
}
