@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// I6 replaces ``NoResponseError`` with the typed ``SendMessageError`` enum so
/// callers can pattern-match each upstream failure mode of the async
/// ``ChatViewModel/sendMessage(_:)`` overload. These tests pin one
/// representative case per arm of the enum.
@MainActor
final class ChatViewModelSendMessageErrorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(
            persistence: SwiftDataPersistenceProvider(modelContext: context),
            autoLoad: false
        )
    }

    override func tearDown() async throws {
        sessionManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(backend: any InferenceBackend, name: String = "MockTest") -> ChatViewModel {
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        return vm
    }

    @discardableResult
    private func createAndActivateSession(vm: ChatViewModel, title: String = "Test Chat") async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - .noActiveSession

    func test_sendMessage_noActiveSession_throwsNoActiveSession() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let vm = makeViewModel(backend: backend)
        // Skip session creation so activeSessionID stays nil.

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.noActiveSession to be thrown")
        } catch SendMessageError.noActiveSession {
            // Pass.
        } catch {
            XCTFail("Expected .noActiveSession, got \(error)")
        }
    }

    // MARK: - .noModelLoaded

    func test_sendMessage_noModelLoaded_throwsNoModelLoaded() async throws {
        // The lifecycle's `InferenceService(backend:name:)` constructor
        // force-flips `isModelLoaded` to true (it's a debug shortcut for
        // test fixtures). Construct InferenceService bare so the lifecycle
        // stays in the unloaded state — that's the path that triggers the
        // .noModelLoaded precondition.
        let service = InferenceService()
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        try await createAndActivateSession(vm: vm)
        XCTAssertFalse(vm.isModelLoaded, "Precondition: model is not loaded")

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.noModelLoaded to be thrown")
        } catch SendMessageError.noModelLoaded {
            // Pass.
        } catch {
            XCTFail("Expected .noModelLoaded, got \(error)")
        }
    }

    // MARK: - .empty

    func test_sendMessage_emptyResponse_throwsEmpty() async throws {
        // The inner sendMessage() drops empty assistant turns silently —
        // lastTurnState stays in `.idle` after the runtime emits
        // FinishReason.empty. The outer sendMessage(_:) overload must
        // surface this as `SendMessageError.empty` so callers can
        // distinguish the no-output case from a real error.
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []  // empty stream
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.empty to be thrown")
        } catch SendMessageError.empty {
            // Pass.
        } catch SendMessageError.runtime(let underlying) {
            XCTFail("Expected .empty, got .runtime(\(underlying))")
        } catch {
            XCTFail("Expected .empty, got \(error)")
        }
    }

    // MARK: - .runtime

    func test_sendMessage_streamFailure_throwsRuntime() async throws {
        // The MidStreamErrorBackend yields some tokens then throws — the
        // turn ends in lastTurnState == .failed(error), which the typed
        // overload must lift into SendMessageError.runtime.
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["partial"],
            errorToThrow: InferenceError.inferenceFailure("simulated stream failure")
        )
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.runtime to be thrown")
        } catch SendMessageError.runtime(let underlying) {
            // The underlying error type is implementation-detail (it can
            // be either the ConversationError wrapping or the raw
            // InferenceError depending on which surfacing path the runtime
            // used). What matters is that .runtime fired, not .empty or
            // a precondition case.
            let description = underlying.localizedDescription
            XCTAssertTrue(
                description.contains("simulated stream failure") || description.contains("Inference"),
                "Underlying error should reference the stream failure, got: \(description)"
            )
        } catch {
            XCTFail("Expected .runtime, got \(error)")
        }
    }

    // MARK: - Happy path returns the assistant record (no throw)

    func test_sendMessage_happyPath_returnsAssistantRecord() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi", " there"]
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        let record = try await vm.sendMessage("hello")
        XCTAssertEqual(record.role, .assistant, "sendMessage(_:) must return the assistant record on success")
        XCTAssertEqual(record.content, "Hi there", "Assistant content should be the streamed tokens")
    }
}
