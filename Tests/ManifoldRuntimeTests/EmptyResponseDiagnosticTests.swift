@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that ``ConversationRuntime`` invokes its empty-response observer
/// (the test-injectable counterpart to the production `Log.warning`) only
/// when the turn loop drops an empty assistant message — i.e. the model
/// produced no visible tokens AND the run was neither cancelled nor failed.
///
/// This is the diagnostic surface added in the #965 fix so a future silent
/// regression of the same shape is observable.
@MainActor
final class EmptyResponseDiagnosticTests: XCTestCase {

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

    /// Thread-safe collector for diagnostics fired off the main actor.
    final class DiagnosticBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConversationRuntime.EmptyResponseDiagnostic] = []
        func append(_ d: ConversationRuntime.EmptyResponseDiagnostic) {
            lock.lock(); defer { lock.unlock() }
            items.append(d)
        }
        var snapshot: [ConversationRuntime.EmptyResponseDiagnostic] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    func test_emptyResponse_firesObserver_andCarriesSessionAndBackend() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []  // produce zero visible tokens

        let inference = InferenceService(backend: backend, name: "EmptyDiagBackend")
        let store = FakeMessageStore()
        let box = DiagnosticBox()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            pipeline: nil,
            emptyResponseObserver: { d in box.append(d) }
        )

        let drain = Task.detached {
            for await _ in runtime.events {}
        }

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "hello"))

        // Wait until the observer fires (or fail).
        let deadline = ContinuousClock.now + .seconds(3)
        while box.snapshot.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        drain.cancel()

        let captured = box.snapshot
        XCTAssertEqual(captured.count, 1, "Empty-response observer must fire exactly once on the drop path")
        XCTAssertEqual(captured.first?.sessionID, sessionID, "Diagnostic must carry the dropped turn's sessionID")
        XCTAssertEqual(captured.first?.backendName, "EmptyDiagBackend", "Diagnostic must carry the active backend name")

        // Persistence side: the empty assistant must NOT be persisted.
        let persisted = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(persisted.filter { $0.role == .assistant }.count, 0,
                       "Empty assistant must remain unpersisted (semantics unchanged)")
    }

    func test_nonEmptyResponse_doesNotFireObserver() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["hi", " there"]

        let inference = InferenceService(backend: backend, name: "GreenBackend")
        let store = FakeMessageStore()
        let box = DiagnosticBox()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            pipeline: nil,
            emptyResponseObserver: { d in box.append(d) }
        )

        let drain = Task.detached {
            for await _ in runtime.events {}
        }

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "hello"))

        // Wait until assistant is persisted (happy path), then verify observer
        // never fired.
        let deadline = ContinuousClock.now + .seconds(3)
        var persistedAsst = false
        while !persistedAsst && ContinuousClock.now < deadline {
            let msgs = try await store.fetchMessages(for: sessionID)
            persistedAsst = msgs.contains { $0.role == .assistant && !$0.content.isEmpty }
            if !persistedAsst { try? await Task.sleep(for: .milliseconds(10)) }
        }
        drain.cancel()

        XCTAssertTrue(persistedAsst, "Happy path: assistant should persist")
        XCTAssertTrue(box.snapshot.isEmpty, "Observer must not fire when the assistant streamed content")
    }

    func test_emptyStreamError_doesNotFireObserver() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []
        backend.shouldThrowInsideStream = InferenceError.inferenceFailure("empty failure")

        let inference = InferenceService(backend: backend, name: "FailingBackend")
        let store = FakeMessageStore()
        let box = DiagnosticBox()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            pipeline: nil,
            emptyResponseObserver: { d in box.append(d) }
        )

        let drain = Task.detached { [runtime] in
            for await event in runtime.events {
                if case .streamFinished = event { return }
            }
        }

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "fail empty"))
        try await wait(for: drain)

        XCTAssertTrue(box.snapshot.isEmpty,
                      "Observer must not fire when an empty turn failed instead of being dropped")
        let persisted = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(persisted.filter { $0.role == .assistant }.count, 0,
                       "Failed empty assistant must remain unpersisted")
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
