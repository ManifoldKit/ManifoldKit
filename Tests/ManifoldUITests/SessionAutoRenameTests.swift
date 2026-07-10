@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class SessionAutoRenameTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        vm = SessionManagerViewModel()
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        vm = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeInferenceService(tokens: [String]) -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        return InferenceService(backend: mock, name: "Mock")
    }

    private func makeThrowingInferenceService() -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Mock failure")
        return InferenceService(backend: mock, name: "Mock")
    }

    // MARK: - Tests

    func test_autoRename_updatesSessionTitle() async {
        let session = try! await vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        let service = makeInferenceService(tokens: ["Travel", " Planning", " Tips"])

        await vm.autoRenameSession(session, firstMessage: "How do I plan a trip?", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Travel Planning Tips")
    }

    func test_autoRename_onError_keepsExistingTitle() async {
        let session = try! await vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        let service = makeThrowingInferenceService()

        await vm.autoRenameSession(session, firstMessage: "Tell me about dogs", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "New Chat")
    }

    func test_autoRename_onError_recordsDiagnosticWarning() async throws {
        // Reconfigure with a diagnostics sink so we can assert surfacing.
        let diagnostics = DiagnosticsService()
        let freshVM = SessionManagerViewModel()
        freshVM.configure(
            persistence: SwiftDataPersistenceProvider(modelContext: context),
            autoLoad: false,
            diagnostics: diagnostics
        )

        let session = try await freshVM.createSession()
        let service = makeThrowingInferenceService()

        await freshVM.autoRenameSession(session, firstMessage: "Tell me about dogs", inferenceService: service)

        XCTAssertEqual(diagnostics.count, 1, "Title generation failure should be recorded on diagnostics")
        if case .titleGenerationFailed(let id, _) = diagnostics.warnings.first?.error {
            XCTAssertEqual(id, session.id)
        } else {
            XCTFail("Expected .titleGenerationFailed warning, got \(String(describing: diagnostics.warnings.first?.error))")
        }
    }

    func test_autoRename_onPersistenceFailure_recordsDistinctDiagnostic() async throws {
        // Wrap the real in-memory provider so createSession's insert goes
        // through, then switch on shouldThrowOnUpdateSession to make the
        // rename path trip. This separates the inference failure path
        // (.titleGenerationFailed) from the persistence failure path
        // (.sessionRenamePersistenceFailed).
        let freshStack = try InMemoryPersistenceHarness.make()
        let wrappedPersistence = ErrorInjectingPersistenceProvider(wrapping: freshStack.provider)
        let diagnostics = DiagnosticsService()
        let freshVM = SessionManagerViewModel()
        freshVM.configure(persistence: wrappedPersistence, autoLoad: false, diagnostics: diagnostics)

        let session = try await freshVM.createSession()
        wrappedPersistence.shouldThrowOnUpdateSession = ChatPersistenceError.providerNotConfigured

        let service = makeInferenceService(tokens: ["Cooking", " Basics"])

        await freshVM.autoRenameSession(session, firstMessage: "What is cooking?", inferenceService: service)

        XCTAssertEqual(diagnostics.count, 1, "Persistence failure should be recorded once")
        guard let recorded = diagnostics.warnings.first?.error else {
            XCTFail("Expected a recorded warning")
            return
        }
        if case .sessionRenamePersistenceFailed(let id, _) = recorded {
            XCTAssertEqual(id, session.id)
        } else {
            XCTFail("Expected .sessionRenamePersistenceFailed, got \(recorded)")
        }
    }

    func test_autoRename_truncatesLongTitle() async {
        let session = try! await vm.createSession()

        // 60-character title returned by the mock
        let longTitle = "This Is A Very Long Title That Definitely Exceeds Fifty Char"
        XCTAssertEqual(longTitle.count, 60)

        let service = makeInferenceService(tokens: [longTitle])

        await vm.autoRenameSession(session, firstMessage: "Some question", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }!
        XCTAssertEqual(updated.title.count, 50)
        XCTAssertEqual(updated.title, String(longTitle.prefix(50)))
    }

    func test_autoRename_trimsWhitespace() async {
        let session = try! await vm.createSession()

        let service = makeInferenceService(tokens: ["  My Title  \n"])

        await vm.autoRenameSession(session, firstMessage: "What is cooking?", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "My Title")
    }

    // MARK: - Enqueue path tests

    /// Verifies that `autoRenameSession` routes title generation through
    /// `enqueue()` rather than the direct `generate()` path. The backend's
    /// `generateCallCount` increments when `enqueue()` dispatches the request,
    /// and the returned title proves the full pipeline executed.
    func test_autoRename_titleGenerationUsesEnqueue_notDirectGenerate() async {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Smart", " Home", " Setup"]
        let service = InferenceService(backend: mock, name: "Mock")

        let session = try! await vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        await vm.autoRenameSession(session, firstMessage: "How do I set up smart home devices?", inferenceService: service)

        // The title being set proves enqueue() routed through to the backend.
        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Smart Home Setup")

        // Exactly one backend generate() call — enqueue dispatches one request.
        XCTAssertEqual(mock.generateCallCount, 1, "enqueue() should call backend.generate() exactly once")
    }

    /// Verifies that a background title-generation request queues behind an
    /// already-active userInitiated request instead of racing with it.
    func test_autoRename_withActiveQueuedGeneration_queuesAsBackground() async {
        // Use a slow backend so the first request stays active long enough
        // for us to observe the background request queuing behind it.
        let slow = SlowMockBackend(tokenCount: 100, delayMilliseconds: 50)
        let service = InferenceService(backend: slow, name: "Mock")

        // Enqueue a high-priority userInitiated request. drainQueue() moves it
        // to the active slot immediately, so requestQueue stays empty.
        let (activeToken, _) = try! service.enqueue(messages: [Message.user("Tell me a long story")], config: GenerationConfig(), priority: .userInitiated, requestGroupID: nil)
        _ = activeToken // silence unused-variable warning

        // Active slot is now occupied. The next enqueue will stay in requestQueue.
        let session = try! await vm.createSession()

        // Fire autoRenameSession in a background Task so it can call enqueue()
        // without blocking the main actor. We capture the task to cancel later.
        let renameTask = Task {
            await vm.autoRenameSession(
                session,
                firstMessage: "How do I set up smart home devices?",
                inferenceService: service
            )
        }

        // Yield to let the Task reach enqueue() before we assert.
        await Task.yield()

        // The background title request should be sitting in the queue behind
        // the active userInitiated request.
        XCTAssertTrue(service.hasQueuedRequests, "Background title request should be queued behind the active userInitiated generation")

        // Clean up: stop active generation and cancel the rename task so the
        // test doesn't leak into subsequent runs.
        service.stopGeneration()
        renameTask.cancel()
    }
}
