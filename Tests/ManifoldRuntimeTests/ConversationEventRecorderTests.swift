@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - ConversationEventRecorderTests

/// Coverage for ``ConversationEventRecorder``.
///
/// Verifies that the recorder captures a full turn trace and that multiple
/// independent recorders on the same runtime each see the complete event
/// sequence without interference.
@MainActor
final class ConversationEventRecorderTests: XCTestCase {

    // MARK: - In-memory MessageStore

    private final class RecorderMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
    }

    // MARK: - Fixture factory

    private func makeRuntime(
        tokens: [String] = ["Hi", " there"]
    ) -> (runtime: ConversationRuntime, mock: MockInferenceBackend) {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RecorderMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)
        return (runtime, mock)
    }

    // MARK: - Tests

    /// A recorder started before a turn captures the full trace including
    /// `streamStarted`, token deltas, and `streamFinished`.
    func test_recorder_capturesFullTrace() async throws {
        let (runtime, _) = makeRuntime(tokens: ["Hello", " recorder"])

        // Drain primary stream.
        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let turn = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "go"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        let outcome = await turn?.outcome
        XCTAssertEqual(outcome?.reason, .stop)
        let messageID = try XCTUnwrap(outcome?.assistantMessageID)

        // Await the drain task to ensure streamFinished is captured.
        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace

        // Must contain streamStarted for this turn.
        let sawStart = trace.contains {
            if case let .streamStarted(id) = $0 { return id == messageID }
            return false
        }
        XCTAssertTrue(sawStart, "recorder must capture streamStarted")

        // Must contain at least one tokenEmitted.
        let tokenCount = trace.filter {
            if case let .tokenEmitted(id, _) = $0 { return id == messageID }
            return false
        }.count
        XCTAssertGreaterThan(tokenCount, 0, "recorder must capture token deltas")

        // Must contain streamFinished.
        let sawFinish = trace.contains {
            if case let .streamFinished(id, _) = $0 { return id == messageID }
            return false
        }
        XCTAssertTrue(sawFinish, "recorder must capture streamFinished")

        // Reassembled text must match scripted output.
        let text = trace.compactMap { event -> String? in
            guard case let .tokenEmitted(id, delta) = event, id == messageID else { return nil }
            return delta
        }.joined()
        XCTAssertEqual(text, "Hello recorder", "recorder must reassemble the full streamed text")
    }

    /// Two independent recorders on the same runtime both capture the full event
    /// sequence without interfering with each other.
    func test_recorder_multipleRecorders() async throws {
        let (runtime, _) = makeRuntime(tokens: ["multi", "cast"])

        // Drain primary stream.
        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        let recorder1 = ConversationEventRecorder()
        let recorder2 = ConversationEventRecorder()

        let drain1 = await recorder1.start(on: runtime)
        let drain2 = await recorder2.start(on: runtime)

        let turn = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "ping"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        let outcome = await turn?.outcome
        XCTAssertEqual(outcome?.reason, .stop)
        let messageID = try XCTUnwrap(outcome?.assistantMessageID)

        // Give both drain tasks time to observe streamFinished.
        drain1.cancel()
        drain2.cancel()
        _ = await drain1.value
        _ = await drain2.value

        let trace1 = await recorder1.trace
        let trace2 = await recorder2.trace

        func tokenText(from trace: [ConversationEvent], id: UUID) -> String {
            trace.compactMap { event -> String? in
                guard case let .tokenEmitted(eID, delta) = event, eID == id else { return nil }
                return delta
            }.joined()
        }

        let text1 = tokenText(from: trace1, id: messageID)
        let text2 = tokenText(from: trace2, id: messageID)
        XCTAssertEqual(text1, "multicast", "recorder1 must capture full token stream")
        XCTAssertEqual(text2, "multicast", "recorder2 must capture the same token stream independently")

        // Both recorders must see streamFinished.
        let finish1 = trace1.contains { if case .streamFinished = $0 { return true }; return false }
        let finish2 = trace2.contains { if case .streamFinished = $0 { return true }; return false }
        XCTAssertTrue(finish1, "recorder1 must observe streamFinished")
        XCTAssertTrue(finish2, "recorder2 must observe streamFinished")
    }
}
