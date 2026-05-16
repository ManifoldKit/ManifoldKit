@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Isolation tests for `ChatPersistenceAdapter`.
///
/// Each test exercises the adapter in isolation — without `ChatViewModel` — to
/// confirm that the adapter's own surface is correct before the full integration
/// tests exercise the wired-up path. Tests 1–4 cover the adapter directly;
/// test 5 confirms the adapter is wired correctly through `ChatViewModel`.
@MainActor
final class ChatPersistenceAdapterTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private func provider() -> any SessionStore & MessageStore {
        SwiftDataPersistenceProvider(modelContext: container.mainContext)
    }

    // MARK: - 1: configure sets persistence on the session controller

    func test_configure_setsSessionControllerPersistence() {
        let adapter = ChatPersistenceAdapter()
        XCTAssertNil(adapter.persistence)

        adapter.configure(persistence: provider())

        XCTAssertNotNil(adapter.persistence)
        XCTAssertNotNil(adapter.sessionController.persistence)
    }

    // MARK: - 2: onPersistenceConfigured fires after configure

    func test_onPersistenceConfigured_firesAfterConfigure() {
        let adapter = ChatPersistenceAdapter()
        var capturedStore: (any SessionStore & MessageStore)?
        adapter.onPersistenceConfigured = { store in
            capturedStore = store
        }

        let p = provider()
        adapter.configure(persistence: p)

        XCTAssertNotNil(capturedStore)
        // Confirm the store passed to the closure is the same object.
        XCTAssertTrue(capturedStore === p)
    }

    // MARK: - 3: loadMessages delegates to session controller without crashing

    func test_loadMessages_delegatesToSessionController() async {
        let adapter = ChatPersistenceAdapter()
        adapter.configure(persistence: provider())

        let session = ChatSessionRecord(title: "Test")
        adapter.activeSession = session

        // Should complete without crashing; no messages in the store.
        await adapter.loadMessages()
        XCTAssertEqual(adapter.messages, [])
    }

    // MARK: - 4: insertSession throws when persistence is not configured

    func test_insertSession_requiresPersistenceOrThrows() async {
        let adapter = ChatPersistenceAdapter()
        // No persistence configured.

        let session = ChatSessionRecord(title: "New Chat")
        do {
            try await adapter.insertSession(session)
            XCTFail("Expected insertSession to throw when persistence is not configured")
        } catch ChatPersistenceError.providerNotConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 5: ChatViewModel.configure wires through to the adapter

    func test_chatViewModelConfigure_wiresTo_adapter() {
        let service = InferenceService(backend: MockInferenceBackend(), name: "Mock")
        let vm = ChatViewModel(inferenceService: service)
        XCTAssertNil(vm.persistenceAdapter.sessionController.persistence)

        // Override the adapter's wiring closure to observe whether
        // `configure(persistence:)` reaches the adapter's
        // `onPersistenceConfigured` contract — not just sets a property the
        // call literally just set. We rebind the closure to one we control,
        // confirm it fires with the exact store identity, then exercise
        // `configure` and assert on both signals.
        var observedStore: (any SessionStore & MessageStore)?
        vm.persistenceAdapter.onPersistenceConfigured = { store in
            observedStore = store
        }

        let p = provider()
        vm.configure(persistence: p)

        XCTAssertNotNil(vm.persistenceAdapter.sessionController.persistence)
        XCTAssertNotNil(observedStore, "onPersistenceConfigured should fire from configure(persistence:)")
        XCTAssertTrue(observedStore === p, "closure should receive the same store identity")
    }
}
