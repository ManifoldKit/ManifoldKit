import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference

@MainActor
final class RuntimeConfigurationTests: XCTestCase {

    func test_configureRuntime_wiresSharedPersistenceAndDiagnostics() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let suiteName = "BaseChatRuntimeConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "Runtime UI Tests",
                bundleIdentifier: "com.basechatkit.runtime-ui-tests"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let chatViewModel = ChatViewModel(
            inferenceService: runtime.inferenceService,
            userDefaults: defaults
        )
        let sessionManager = SessionManagerViewModel()

        chatViewModel.configure(runtime: runtime)
        sessionManager.configure(runtime: runtime)

        guard let chatPersistence = chatViewModel.persistence else {
            XCTFail("ChatViewModel should be configured with runtime persistence")
            return
        }
        guard let managerPersistence = sessionManager.persistence else {
            XCTFail("SessionManagerViewModel should be configured with runtime persistence")
            return
        }

        XCTAssertTrue(chatPersistence === runtime.persistence)
        XCTAssertTrue(managerPersistence === runtime.persistence)
        XCTAssertTrue(sessionManager.diagnostics === runtime.diagnostics)

        let created = try sessionManager.createSession(title: "Runtime Session")
        XCTAssertEqual(try runtime.persistence.fetchSessions().map(\.id), [created.id])
    }

    func test_runtimeBootstrap_canSeedAndActivateInitialSessionWithoutViewLifecycleHooks() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let suiteName = "BaseChatRuntimeBootstrapTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "Bootstrap Tests",
                bundleIdentifier: "com.basechatkit.runtime-ui-tests.bootstrap"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let chatViewModel = ChatViewModel(
            inferenceService: runtime.inferenceService,
            userDefaults: defaults
        )
        let sessionManager = SessionManagerViewModel()

        chatViewModel.configure(runtime: runtime)
        sessionManager.configure(runtime: runtime)
        chatViewModel.refreshModels()

        let initialSession = sessionManager.sessions.first ?? (try? sessionManager.createSession())
        guard let initialSession else {
            XCTFail("Bootstrap should create or restore an initial session")
            return
        }

        sessionManager.activeSession = initialSession
        chatViewModel.switchToSession(initialSession)
        chatViewModel.dispatchSelectedLoad()

        XCTAssertEqual(sessionManager.activeSession?.id, initialSession.id)
        XCTAssertEqual(chatViewModel.activeSession?.id, initialSession.id)
        XCTAssertEqual(try runtime.persistence.fetchSessions().map(\.id), [initialSession.id])
    }
}
