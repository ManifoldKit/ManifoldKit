@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

// MARK: - Session Override Tests

@MainActor
final class SessionOverrideTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mockBackend: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mockBackend = MockInferenceBackend()
        mockBackend.isModelLoaded = true
        mockBackend.tokensToYield = ["ok"]

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let service = InferenceService(backend: mockBackend, name: "Mock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        mockBackend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(
        title: String = "Test Chat",
        temperature: Float? = nil,
        topP: Float? = nil,
        repeatPenalty: Float? = nil
    ) async throws -> ManifoldInference.ChatSession {
        var session = try await sessionManager.createSession(title: title)
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func sendMessage(_ text: String = "Hello") async {
        vm.inputText = text
        await vm.sendMessage()
    }

    // MARK: - Tests

    func test_customOverrides_passedToBackend() async throws {
        try await createAndActivateSession(
            title: "Custom",
            temperature: 0.3,
            topP: 0.5,
            repeatPenalty: 1.5
        )

        await sendMessage()

        let config = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(config.temperature, 0.3, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
    }

    func test_noOverrides_usesDefaults() async throws {
        try await createAndActivateSession(title: "Default")

        await sendMessage()

        let config = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001)
    }

    func test_switchBackToCustomSession_overridesStillApplied() async throws {
        // Session A: custom overrides
        let sessionA = try await createAndActivateSession(
            title: "Session A",
            temperature: 0.3,
            topP: 0.5,
            repeatPenalty: 1.5
        )

        await sendMessage("From A first")

        // Session B: defaults
        try await createAndActivateSession(title: "Session B")

        await sendMessage("From B")

        let defaultConfig = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(defaultConfig.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(defaultConfig.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(defaultConfig.repeatPenalty, 1.1, accuracy: 0.001)

        // Switch back to Session A
        await vm.switchToSession(sessionA)

        await sendMessage("From A again")

        let overriddenConfig = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(overriddenConfig.temperature, 0.3, accuracy: 0.001)
        XCTAssertEqual(overriddenConfig.topP, 0.5, accuracy: 0.001)
        XCTAssertEqual(overriddenConfig.repeatPenalty, 1.5, accuracy: 0.001)
    }
}
