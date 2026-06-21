@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the `respond(to:)` String-typed convenience over `sendMessage(_:)`.
///
/// `respond(to:)` is a thin wrapper that returns `sendMessage(text).content`, so
/// these tests verify it (1) returns the assistant's reply text on the happy
/// path and (2) propagates the same `SendMessageError` rim as `sendMessage`.
@MainActor
final class ChatViewModelRespondTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: mock, name: "MockRespond")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
    }

    override func tearDown() async throws {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    @discardableResult
    private func createAndActivateSession(title: String = "Respond Chat") async -> ManifoldInference.ChatSession {
        let session = try! await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - Happy path

    func testRespondReturnsAssistantReplyText() async throws {
        await createAndActivateSession()

        let reply = try await vm.respond(to: "Hi there")

        XCTAssertEqual(reply, "Hello world", "respond(to:) should return the concatenated assistant token text")
    }

    // MARK: - Precondition errors

    func testRespondThrowsNoModelLoadedWhenModelMissing() async throws {
        await createAndActivateSession()
        // The test-injection InferenceService init marks the lifecycle loaded;
        // unload so `vm.isModelLoaded` (which proxies the service) is false and
        // the precondition fires before the runtime is invoked.
        vm.inferenceService.unloadModel()

        do {
            _ = try await vm.respond(to: "Hi there")
            XCTFail("Expected respond(to:) to throw when no model is loaded")
        } catch let error as SendMessageError {
            guard case .noModelLoaded = error else {
                return XCTFail("Expected .noModelLoaded, got \(error)")
            }
        }
    }

    func testRespondThrowsNoActiveSessionWhenNoSession() async throws {
        // No session activated.
        do {
            _ = try await vm.respond(to: "Hi there")
            XCTFail("Expected respond(to:) to throw when no session is active")
        } catch let error as SendMessageError {
            guard case .noActiveSession = error else {
                return XCTFail("Expected .noActiveSession, got \(error)")
            }
        }
    }

    // MARK: - Runtime error

    func testRespondThrowsRuntimeWhenBackendErrors() async throws {
        await createAndActivateSession()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("boom")

        do {
            _ = try await vm.respond(to: "Hi there")
            XCTFail("Expected respond(to:) to throw when the backend errors")
        } catch let error as SendMessageError {
            guard case .runtime = error else {
                return XCTFail("Expected .runtime, got \(error)")
            }
        }
    }
}
