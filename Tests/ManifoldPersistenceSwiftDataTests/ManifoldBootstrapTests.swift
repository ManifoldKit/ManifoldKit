import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference

@MainActor
final class ManifoldBootstrapTests: XCTestCase {

    func test_init_installsConfigurationBeforeBuildingModelContainer() throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let bundleIdentifier = "com.manifoldkit.runtime-tests.\(UUID().uuidString)"
        var bundleIdentifierSeenDuringContainerBuild: String?

        _ = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Runtime Tests",
                bundleIdentifier: bundleIdentifier
            ),
            makeModelContainer: {
                bundleIdentifierSeenDuringContainerBuild = ManifoldConfiguration.shared.bundleIdentifier
                return try ModelContainerFactory.makeInMemoryContainer()
            }
        )

        XCTAssertEqual(bundleIdentifierSeenDuringContainerBuild, bundleIdentifier)
    }

    func test_init_usesInjectedInferenceServiceInstance() throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let service = InferenceService()
        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Injected Service",
                bundleIdentifier: "com.manifoldkit.runtime-tests.injected"
            ),
            inferenceService: service,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertTrue(runtime.inferenceService === service)
    }

    func test_init_throwingMakeModelContainer_restoresConfiguration() {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let distinctConfiguration = ManifoldConfiguration(
            appName: "Rollback Test",
            bundleIdentifier: "com.manifoldkit.runtime-tests.rollback.\(UUID().uuidString)"
        )

        XCTAssertNotEqual(distinctConfiguration.bundleIdentifier, originalConfiguration.bundleIdentifier)

        XCTAssertThrowsError(
            try ManifoldBootstrap(
                configuration: distinctConfiguration,
                makeModelContainer: { throw URLError(.cannotOpenFile) }
            )
        )

        XCTAssertEqual(
            ManifoldConfiguration.shared.bundleIdentifier,
            originalConfiguration.bundleIdentifier,
            "ManifoldConfiguration.shared should roll back to its prior value when bootstrap throws"
        )
    }

    func test_init_wiresInferenceServicePersistenceAndContainerToTheSameInstances() async throws {
        // Defends the post-construction wiring identity that the deleted
        // `Event`-callback ordering test used to defend: the runtime must
        // expose the *same* InferenceService instance the caller injected,
        // the *same* ModelContainer instance the closure produced, and a
        // SwiftDataPersistenceProvider whose modelContext is anchored to
        // that container's mainContext. Sabotage the assignment of any of
        // these properties in `ManifoldBootstrap.init` and one of the
        // assertions below will fail.
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let injectedInferenceService = InferenceService()
        let resolvedContainer = try ModelContainerFactory.makeInMemoryContainer()
        var capturedContainerDuringClosure: ModelContainer?

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Wiring Identity",
                bundleIdentifier: "com.manifoldkit.runtime-tests.wiring.\(UUID().uuidString)"
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

    func test_init_endpointStoreSharesContainerWithPersistence() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Endpoint Store Wiring",
                bundleIdentifier: "com.manifoldkit.runtime-tests.endpoint-store.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let endpoint = APIEndpointRecord(name: "Shared Endpoint", provider: .openAI)
        var session = ChatSessionRecord(title: "Shared Session")
        session.selectedEndpointID = endpoint.id

        try await runtime.endpointStore.insertEndpoint(endpoint)
        try await runtime.persistence.insertSession(session)

        let endpointsViaContainer = try runtime.modelContainer.mainContext.fetch(FetchDescriptor<APIEndpoint>())
        let sessionsViaPersistence = try await runtime.persistence.fetchSessions()

        XCTAssertTrue(endpointsViaContainer.contains(where: { $0.id == endpoint.id }),
            "Endpoint inserted through runtime.endpointStore must be visible through runtime.modelContainer.mainContext")
        XCTAssertEqual(sessionsViaPersistence.first(where: { $0.id == session.id })?.selectedEndpointID, endpoint.id,
            "Session settings persisted through runtime.persistence must reference the same endpoint id")
    }

    func test_persistence_roundTripsSessionsThroughRuntimeProvider() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Persistence Round Trip",
                bundleIdentifier: "com.manifoldkit.runtime-tests.persistence"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let session = ChatSessionRecord(title: "Runtime Session")

        try await runtime.persistence.insertSession(session)

        let sessions = try await runtime.persistence.fetchSessions()
        XCTAssertEqual(sessions.map(\.id), [session.id])
    }
}
