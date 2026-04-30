import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference

@MainActor
final class RuntimeConfigurationTests: XCTestCase {

    func test_configureRuntime_wiresSharedPersistenceAndDiagnostics() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let suiteName = "BaseChatRuntimeConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try BaseChatBootstrap(
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

        let created = try await sessionManager.createSession(title: "Runtime Session")
        let persistedIDs = try await runtime.persistence.fetchSessions().map(\.id)
        XCTAssertEqual(persistedIDs, [created.id])

        // `configure(runtime:)` schedules a fire-and-forget `loadSessions()`
        // (autoLoad: true). Drain it before the runtime / SwiftData container
        // tears down, otherwise the in-flight fetch races teardown and traps.
        await sessionManager.autoLoadTask?.value
    }

    func test_runtimeBootstrap_canSeedAndActivateInitialSessionWithoutViewLifecycleHooks() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let suiteName = "BaseChatRuntimeBootstrapTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try BaseChatBootstrap(
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
        // `configure(runtime:)` schedules a fire-and-forget `loadSessions()`.
        // Drain it deterministically so the explicit reload below is the
        // observed sequence and the in-flight fetch can't race teardown.
        await sessionManager.autoLoadTask?.value
        // Phase 1.0: `configure` no longer auto-fires `loadSessions()`.
        // Hosts that bypass `SessionListView` (which calls it from
        // `.task { }`) must load explicitly during bootstrap.
        await sessionManager.loadSessions()

        let resolvedInitial: ChatSessionRecord?
        if let existing = sessionManager.sessions.first {
            resolvedInitial = existing
        } else {
            resolvedInitial = try? await sessionManager.createSession()
        }
        guard let initialSession = resolvedInitial else {
            XCTFail("Bootstrap should create or restore an initial session")
            return
        }

        sessionManager.activeSession = initialSession
        await chatViewModel.switchToSession(initialSession)
        chatViewModel.dispatchSelectedLoad()

        XCTAssertEqual(sessionManager.activeSession?.id, initialSession.id)
        XCTAssertEqual(chatViewModel.activeSession?.id, initialSession.id)
        let persistedIDs = try await runtime.persistence.fetchSessions().map(\.id)
        XCTAssertEqual(persistedIDs, [initialSession.id])
    }
}
