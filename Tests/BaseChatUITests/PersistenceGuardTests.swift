@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// Coverage for the `requirePersistence` / `persistenceOrLog` helpers added in
/// `Sources/BaseChatUI/Internal/PersistenceGuard.swift`. Twelve cases — three
/// holding types (`SessionController`, `SessionManagerViewModel`,
/// `ChatViewModel`) crossed with two helpers and the configured / not-configured
/// states — keep the helper from regressing as new call sites adopt it.
@MainActor
final class PersistenceGuardTests: XCTestCase {

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

    // MARK: - SessionController

    func test_sessionController_requirePersistence_throwsWhenNil() {
        let sut = SessionController()
        XCTAssertThrowsError(try sut.requirePersistence("ctx")) { error in
            switch error {
            case ChatPersistenceError.providerNotConfigured:
                break
            default:
                XCTFail("Expected providerNotConfigured, got \(error)")
            }
        }
    }

    func test_sessionController_requirePersistence_returnsProviderWhenConfigured() throws {
        let sut = SessionController()
        let provider = provider()
        sut.persistence = provider
        let resolved = try sut.requirePersistence("ctx")
        XCTAssertTrue(resolved === provider)
    }

    func test_sessionController_persistenceOrLog_returnsNilWhenNil() {
        let sut = SessionController()
        XCTAssertNil(sut.persistenceOrLog("ctx"))
    }

    func test_sessionController_persistenceOrLog_returnsProviderWhenConfigured() {
        let sut = SessionController()
        let provider = provider()
        sut.persistence = provider
        let resolved = sut.persistenceOrLog("ctx")
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved === provider)
    }

    // MARK: - SessionManagerViewModel

    func test_sessionManager_requirePersistence_throwsWhenNil() {
        let sut = SessionManagerViewModel()
        XCTAssertThrowsError(try sut.requirePersistence("ctx")) { error in
            switch error {
            case ChatPersistenceError.providerNotConfigured:
                break
            default:
                XCTFail("Expected providerNotConfigured, got \(error)")
            }
        }
    }

    func test_sessionManager_requirePersistence_returnsProviderWhenConfigured() throws {
        let sut = SessionManagerViewModel()
        let provider = provider()
        sut.configure(persistence: provider, autoLoad: false)
        let resolved = try sut.requirePersistence("ctx")
        XCTAssertTrue(resolved === provider)
    }

    func test_sessionManager_persistenceOrLog_returnsNilWhenNil() {
        let sut = SessionManagerViewModel()
        XCTAssertNil(sut.persistenceOrLog("ctx"))
    }

    func test_sessionManager_persistenceOrLog_returnsProviderWhenConfigured() {
        let sut = SessionManagerViewModel()
        let provider = provider()
        sut.configure(persistence: provider, autoLoad: false)
        let resolved = sut.persistenceOrLog("ctx")
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved === provider)
    }

    // MARK: - ChatViewModel

    func test_chatViewModel_requirePersistence_throwsWhenNil() {
        let sut = ChatViewModel(inferenceService: InferenceService(backend: MockInferenceBackend(), name: "Mock"))
        XCTAssertThrowsError(try sut.requirePersistence("ctx")) { error in
            switch error {
            case ChatPersistenceError.providerNotConfigured:
                break
            default:
                XCTFail("Expected providerNotConfigured, got \(error)")
            }
        }
    }

    func test_chatViewModel_requirePersistence_returnsProviderWhenConfigured() throws {
        let sut = ChatViewModel(inferenceService: InferenceService(backend: MockInferenceBackend(), name: "Mock"))
        let provider = provider()
        sut.configure(persistence: provider)
        let resolved = try sut.requirePersistence("ctx")
        XCTAssertTrue(resolved === provider)
    }

    func test_chatViewModel_persistenceOrLog_returnsNilWhenNil() {
        let sut = ChatViewModel(inferenceService: InferenceService(backend: MockInferenceBackend(), name: "Mock"))
        XCTAssertNil(sut.persistenceOrLog("ctx"))
    }

    func test_chatViewModel_persistenceOrLog_returnsProviderWhenConfigured() {
        let sut = ChatViewModel(inferenceService: InferenceService(backend: MockInferenceBackend(), name: "Mock"))
        let provider = provider()
        sut.configure(persistence: provider)
        let resolved = sut.persistenceOrLog("ctx")
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved === provider)
    }
}
