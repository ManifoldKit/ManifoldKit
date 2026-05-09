import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

@MainActor
final class RuntimeConfigurationTests: XCTestCase {

    func test_configureRuntime_wiresSharedPersistenceAndDiagnostics() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let suiteName = "ManifoldRuntimeConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Runtime UI Tests",
                bundleIdentifier: "com.manifoldkit.runtime-ui-tests"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: modelsDirectory) }

        let chatViewModel = ChatViewModel(
            inferenceService: runtime.inferenceService,
            modelStorage: ModelStorageService(baseDirectory: modelsDirectory),
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
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let suiteName = "ManifoldRuntimeBootstrapTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Bootstrap Tests",
                bundleIdentifier: "com.manifoldkit.runtime-ui-tests.bootstrap"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeBootstrapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: modelsDirectory) }

        let chatViewModel = ChatViewModel(
            inferenceService: runtime.inferenceService,
            modelStorage: ModelStorageService(baseDirectory: modelsDirectory),
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

    func test_configureRuntime_loadsEndpointsAndSwitchUsesFreshEndpointRecords() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Endpoint Bootstrap Tests",
                bundleIdentifier: "com.manifoldkit.runtime-ui-tests.endpoints"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let endpointID = UUID()
        let originalEndpoint = APIEndpointRecord(
            id: endpointID,
            name: "Original Endpoint",
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            modelName: "old-model"
        )
        try await runtime.endpointStore.insertEndpoint(originalEndpoint)

        var session = ChatSessionRecord(title: "Endpoint Session")
        session.selectedEndpointID = endpointID
        try await runtime.persistence.insertSession(session)

        let chatViewModel = ChatViewModel(inferenceService: runtime.inferenceService)
        chatViewModel.configure(runtime: runtime)
        await chatViewModel.endpointRefreshTask?.value

        XCTAssertEqual(chatViewModel.availableEndpoints.map(\.id), [endpointID],
            "configure(runtime:) should load selectable endpoints through the runtime endpoint store")

        var freshEndpoint = originalEndpoint
        freshEndpoint.name = "Fresh Endpoint"
        freshEndpoint.modelName = "fresh-model"
        try await runtime.endpointStore.updateEndpoint(freshEndpoint)

        await chatViewModel.switchToSession(session)

        XCTAssertEqual(chatViewModel.selectedEndpoint?.id, endpointID)
        XCTAssertEqual(chatViewModel.selectedEndpoint?.name, "Fresh Endpoint",
            "switchToSession should resolve selectedEndpointID from freshly fetched endpoint records")
        XCTAssertEqual(chatViewModel.selectedEndpoint?.modelName, "fresh-model")
    }
}
