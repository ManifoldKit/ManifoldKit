import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatInference

@MainActor
final class BaseChatBootstrapTests: XCTestCase {

    func test_init_installsConfigurationBeforeBuildingModelContainer() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let bundleIdentifier = "com.basechatkit.runtime-tests.\(UUID().uuidString)"
        var bundleIdentifierSeenDuringContainerBuild: String?

        _ = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Runtime Tests",
                bundleIdentifier: bundleIdentifier
            ),
            makeModelContainer: {
                bundleIdentifierSeenDuringContainerBuild = BaseChatConfiguration.shared.bundleIdentifier
                return try ModelContainerFactory.makeInMemoryContainer()
            }
        )

        XCTAssertEqual(bundleIdentifierSeenDuringContainerBuild, bundleIdentifier)
    }

    func test_init_usesInjectedInferenceServiceInstance() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let service = InferenceService()
        let runtime = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Injected Service",
                bundleIdentifier: "com.basechatkit.runtime-tests.injected"
            ),
            inferenceService: service,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertTrue(runtime.inferenceService === service)
    }

    func test_init_throwingMakeModelContainer_restoresConfiguration() {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let distinctConfiguration = BaseChatConfiguration(
            appName: "Rollback Test",
            bundleIdentifier: "com.basechatkit.runtime-tests.rollback.\(UUID().uuidString)"
        )

        XCTAssertNotEqual(distinctConfiguration.bundleIdentifier, originalConfiguration.bundleIdentifier)

        XCTAssertThrowsError(
            try BaseChatBootstrap(
                configuration: distinctConfiguration,
                makeModelContainer: { throw URLError(.cannotOpenFile) }
            )
        )

        XCTAssertEqual(
            BaseChatConfiguration.shared.bundleIdentifier,
            originalConfiguration.bundleIdentifier,
            "BaseChatConfiguration.shared should roll back to its prior value when bootstrap throws"
        )
    }

    func test_init_wiresInferenceServicePersistenceAndContainerToTheSameInstances() async throws {
        // Defends the post-construction wiring identity that the deleted
        // `Event`-callback ordering test used to defend: the runtime must
        // expose the *same* InferenceService instance the caller injected,
        // the *same* ModelContainer instance the closure produced, and a
        // SwiftDataPersistenceProvider whose modelContext is anchored to
        // that container's mainContext. Sabotage the assignment of any of
        // these properties in `BaseChatBootstrap.init` and one of the
        // assertions below will fail.
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let injectedInferenceService = InferenceService()
        let resolvedContainer = try ModelContainerFactory.makeInMemoryContainer()
        var capturedContainerDuringClosure: ModelContainer?

        let runtime = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Wiring Identity",
                bundleIdentifier: "com.basechatkit.runtime-tests.wiring.\(UUID().uuidString)"
            ),
            inferenceService: injectedInferenceService,
            makeModelContainer: {
                capturedContainerDuringClosure = resolvedContainer
                return resolvedContainer
            }
        )

        XCTAssertTrue(runtime.inferenceService === injectedInferenceService,
            "Runtime must expose the injected InferenceService instance")
        XCTAssertNotNil(capturedContainerDuringClosure,
            "makeModelContainer closure must run during bootstrap")
        XCTAssertTrue(runtime.modelContainer === resolvedContainer,
            "Runtime's modelContainer must be the instance the closure produced")

        // The persistence provider's modelContext is private, so we defend
        // its anchoring indirectly: a session inserted through the provider
        // must be reachable via the runtime's modelContainer.mainContext —
        // proof that both surfaces are wired to a single coherent store.
        let session = ChatSessionRecord(title: "Wiring Identity Probe")
        try await runtime.persistence.insertSession(session)
        let descriptor = FetchDescriptor<ChatSession>()
        let entitiesViaContainer = try runtime.modelContainer.mainContext.fetch(descriptor)
        XCTAssertTrue(entitiesViaContainer.contains(where: { $0.id == session.id }),
            "Session inserted via runtime.persistence must be visible through runtime.modelContainer.mainContext")
    }

    func test_persistence_roundTripsSessionsThroughRuntimeProvider() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let runtime = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Persistence Round Trip",
                bundleIdentifier: "com.basechatkit.runtime-tests.persistence"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let session = ChatSessionRecord(title: "Runtime Session")

        try await runtime.persistence.insertSession(session)

        let sessions = try await runtime.persistence.fetchSessions()
        XCTAssertEqual(sessions.map(\.id), [session.id])
    }
}
