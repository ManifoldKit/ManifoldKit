import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class RuntimeConfigurationTests: XCTestCase {

    func test_configureRuntime_wiresSharedPersistenceAndDiagnostics() async throws {
        try await BaseChatConfigurationTestMonitor.shared.withCurrentConfiguration {
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
    }

    func test_runtimeBootstrap_canSeedAndActivateInitialSessionWithoutViewLifecycleHooks() async throws {
        try await BaseChatConfigurationTestMonitor.shared.withCurrentConfiguration {
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
            await sessionManager.autoLoadTask?.value

            let seeded = try await sessionManager.createSession(title: "Seeded Session")
            sessionManager.activeSession = seeded
            await chatViewModel.switchToSession(seeded)

            XCTAssertEqual(chatViewModel.activeSessionID, seeded.id,
                "switchToSession must wire the active session without a view lifecycle hook")
        }
    }
}
