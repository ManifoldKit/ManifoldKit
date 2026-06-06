@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies the auxiliary backend slot on ``ConversationRuntime``.
///
/// Title generation and other cheap framework-internal classification calls
/// should route to ``ConversationRuntime/auxiliaryInferenceService`` when set,
/// leaving the user's chosen model free for real conversation turns.
@MainActor
final class AuxiliaryInferenceServiceTests: XCTestCase {

    // MARK: - Minimal in-memory stores

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

    // MARK: - Helpers

    private func makeBackend(tokens: [String]) -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokens
        return backend
    }

    private func makeService(_ backend: MockInferenceBackend, name: String) -> InferenceService {
        InferenceService(backend: backend, name: name)
    }

    // MARK: - classificationService fallback

    func test_classificationService_returnsAuxiliary_whenSet() {
        let primaryBackend = makeBackend(tokens: ["Primary"])
        let auxiliaryBackend = makeBackend(tokens: ["Auxiliary"])
        let primary = makeService(primaryBackend, name: "Primary")
        let auxiliary = makeService(auxiliaryBackend, name: "Auxiliary")

        let runtime = ConversationRuntime(
            messageStore: FakeMessageStore(),
            inferenceService: primary,
            auxiliaryInferenceService: auxiliary
        )

        XCTAssertIdentical(
            runtime.classificationService as AnyObject,
            auxiliary as AnyObject,
            "classificationService must return auxiliaryInferenceService when set"
        )
    }

    func test_classificationService_returnsPrimary_whenAuxiliaryIsNil() {
        let primaryBackend = makeBackend(tokens: ["Primary"])
        let primary = makeService(primaryBackend, name: "Primary")

        let runtime = ConversationRuntime(
            messageStore: FakeMessageStore(),
            inferenceService: primary
            // auxiliaryInferenceService defaults to nil
        )

        XCTAssertNil(runtime.auxiliaryInferenceService,
                     "auxiliaryInferenceService must default to nil")
        XCTAssertIdentical(
            runtime.classificationService as AnyObject,
            primary as AnyObject,
            "classificationService must fall back to inferenceService when auxiliary is nil"
        )
    }

    // MARK: - Title generation routes to auxiliary

    func test_titleGeneration_usesAuxiliary_whenSet() async throws {
        let primaryBackend = makeBackend(tokens: ["Wrong"])
        let auxiliaryBackend = makeBackend(tokens: ["Trip", " Planning"])
        let primary = makeService(primaryBackend, name: "Primary")
        let auxiliary = makeService(auxiliaryBackend, name: "Auxiliary")

        let runtime = ConversationRuntime(
            messageStore: FakeMessageStore(),
            inferenceService: primary,
            auxiliaryInferenceService: auxiliary
        )

        // SessionListService receives the classificationService from the runtime.
        let store = InMemorySessionAndMessageStore()
        let sls = SessionListService(persistence: store)
        let session = try await sls.createSession()

        await sls.autoRenameSession(
            session,
            firstMessage: "How do I plan a road trip?",
            inferenceService: runtime.classificationService
        )

        // The auxiliary backend was called; the primary was not.
        XCTAssertEqual(auxiliaryBackend.generateCallCount, 1,
                       "Auxiliary backend must be used for title generation")
        XCTAssertEqual(primaryBackend.generateCallCount, 0,
                       "Primary backend must NOT be called for title generation when auxiliary is set")
    }

    func test_titleGeneration_usesPrimary_whenAuxiliaryIsNil() async throws {
        let primaryBackend = makeBackend(tokens: ["Road", " Trip"])
        let primary = makeService(primaryBackend, name: "Primary")

        let runtime = ConversationRuntime(
            messageStore: FakeMessageStore(),
            inferenceService: primary
        )

        let store = InMemorySessionAndMessageStore()
        let sls = SessionListService(persistence: store)
        let session = try await sls.createSession()

        await sls.autoRenameSession(
            session,
            firstMessage: "How do I plan a road trip?",
            inferenceService: runtime.classificationService
        )

        // When there is no auxiliary, classificationService IS the primary.
        XCTAssertEqual(primaryBackend.generateCallCount, 1,
                       "Primary backend must be used when auxiliary is nil")
    }

    // MARK: - Init default — no auxiliary

    func test_convenienceInit_defaultsAuxiliaryToNil() {
        let primary = makeService(makeBackend(tokens: []), name: "Primary")
        let runtime = ConversationRuntime(
            messageStore: FakeMessageStore(),
            inferenceService: primary
        )
        XCTAssertNil(runtime.auxiliaryInferenceService,
                     "Convenience init must default auxiliaryInferenceService to nil (no breaking change)")
    }
}

// MARK: - In-memory SessionStore + MessageStore

/// Minimal combined in-memory store for SessionListService tests.
@MainActor
private final class InMemorySessionAndMessageStore: SessionStore, MessageStore {
    private(set) var sessions: [UUID: ChatSession] = [:]
    private(set) var messages: [UUID: ChatMessage] = [:]

    // SessionStore
    func insertSession(_ session: ChatSession) async throws {
        sessions[session.id] = session
    }
    func updateSession(_ session: ChatSession) async throws {
        sessions[session.id] = session
    }
    func deleteSession(_ id: UUID) async throws {
        sessions.removeValue(forKey: id)
    }
    func fetchSessions() async throws -> [ChatSession] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MessageStore
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
}
