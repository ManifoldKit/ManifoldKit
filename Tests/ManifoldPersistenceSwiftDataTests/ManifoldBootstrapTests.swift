import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldRuntime

@MainActor
final class ManifoldBootstrapTests: XCTestCase {

    private struct ForcedFailure: Error {}

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

    func test_overlappingConstruction_rejectsSyncInMemoryAndBothAsyncOverloads() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let activeConfiguration = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.active.\(UUID().uuidString)"
        )
        let rejectedConfiguration = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.rejected.\(UUID().uuidString)"
        )
        let (arrivals, arrivalContinuation) = AsyncStream.makeStream(
            of: RuntimeBootstrapMilestone.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (releases, releaseContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (_, activeTask) = ManifoldBootstrap.build(
            configuration: activeConfiguration,
            enableResumableRuns: false,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            constructionCheckpoint: { milestone in
                guard milestone == .installingConfiguration else { return }
                arrivalContinuation.yield(milestone)
                var iterator = releases.makeAsyncIterator()
                _ = await iterator.next()
            }
        )

        var arrivalIterator = arrivals.makeAsyncIterator()
        let reachedMilestone = await arrivalIterator.next()
        XCTAssertEqual(reachedMilestone, .installingConfiguration)
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, activeConfiguration.bundleIdentifier)

        XCTAssertThrowsError(
            try ManifoldBootstrap(
                configuration: rejectedConfiguration,
                makeModelContainer: {
                    XCTFail("Rejected synchronous construction must fail before building storage")
                    return try ModelContainerFactory.makeInMemoryContainer()
                }
            )
        ) { error in
            XCTAssertEqual(error as? ManifoldBootstrapError, .constructionInProgress)
        }

        XCTAssertThrowsError(
            try ManifoldBootstrap.makeInMemory(configuration: rejectedConfiguration)
        ) { error in
            XCTAssertEqual(error as? ManifoldBootstrapError, .constructionInProgress)
        }

        // Create both rejected tasks before awaiting either one. The barrier
        // keeps the active bootstrap pinned at the installed milestone.
        let (_, publicTask) = ManifoldBootstrap.build(
            configuration: rejectedConfiguration,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let (_, packageTask) = ManifoldBootstrap.build(
            configuration: rejectedConfiguration,
            enableResumableRuns: true,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        await assertConstructionInProgress(publicTask)
        await assertConstructionInProgress(packageTask)
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, activeConfiguration.bundleIdentifier)

        releaseContinuation.yield()
        releaseContinuation.finish()
        let activeBootstrap = try await activeTask.value

        let session = ManifoldInference.ChatSession(title: "Coordinator persistence probe")
        try await activeBootstrap.persistence.insertSession(session)
        let persistedSessions = try await activeBootstrap.persistence.fetchSessions()
        XCTAssertEqual(persistedSessions.map(\.id), [session.id])
    }

    func test_asyncBuild_directWriterDuringMilestoneFailsAndPreservesWriter() async {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let replacement = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.replacement.\(UUID().uuidString)"
        )
        let (arrivals, arrivalContinuation) = AsyncStream.makeStream(
            of: RuntimeBootstrapMilestone.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (releases, releaseContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let owner = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.owner.\(UUID().uuidString)"
        )
        let (_, task) = ManifoldBootstrap.build(
            configuration: owner,
            enableResumableRuns: false,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            constructionCheckpoint: { milestone in
                guard milestone == .installingConfiguration else { return }
                arrivalContinuation.yield(milestone)
                var iterator = releases.makeAsyncIterator()
                _ = await iterator.next()
            }
        )

        var arrivalIterator = arrivals.makeAsyncIterator()
        let reachedMilestone = await arrivalIterator.next()
        XCTAssertEqual(reachedMilestone, .installingConfiguration)
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, owner.bundleIdentifier)

        ManifoldConfiguration.shared = replacement
        releaseContinuation.yield()
        releaseContinuation.finish()

        do {
            _ = try await task.value
            XCTFail("A bootstrap whose configuration was replaced must not return a mixed graph")
        } catch {
            XCTAssertEqual(error as? ManifoldBootstrapError, .configurationChanged)
        }
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, replacement.bundleIdentifier)
    }

    func test_syncConstruction_directWriterBeforeReturnFailsAndPreservesWriter() {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let replacement = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.sync-replacement.\(UUID().uuidString)"
        )
        XCTAssertThrowsError(
            try ManifoldBootstrap(
                configuration: ManifoldConfiguration(
                    bundleIdentifier: "com.manifoldkit.runtime-tests.sync-owner.\(UUID().uuidString)"
                ),
                makeModelContainer: {
                    ManifoldConfiguration.shared = replacement
                    return try ModelContainerFactory.makeInMemoryContainer()
                }
            )
        ) { error in
            XCTAssertEqual(error as? ManifoldBootstrapError, .configurationChanged)
        }
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, replacement.bundleIdentifier)
    }

    func test_asyncBuild_directWriterInsideContainerFactoryFailsAndPreservesWriter() async {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let replacement = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.container-replacement.\(UUID().uuidString)"
        )
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                bundleIdentifier: "com.manifoldkit.runtime-tests.container-owner.\(UUID().uuidString)"
            ),
            makeModelContainer: {
                ManifoldConfiguration.shared = replacement
                return try ModelContainerFactory.makeInMemoryContainer()
            }
        )
        for await _ in progress {}

        do {
            _ = try await task.value
            XCTFail("A bootstrap whose configuration was replaced must not return a mixed graph")
        } catch {
            XCTAssertEqual(error as? ManifoldBootstrapError, .configurationChanged)
        }
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, replacement.bundleIdentifier)
    }

    func test_asyncBuild_failureWhileOwningInstallationRestoresPreviousConfiguration() async {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let previous = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.previous.\(UUID().uuidString)"
        )
        ManifoldConfiguration.shared = previous
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                bundleIdentifier: "com.manifoldkit.runtime-tests.failing.\(UUID().uuidString)"
            ),
            makeModelContainer: { throw ForcedFailure() }
        )
        for await _ in progress {}

        do {
            _ = try await task.value
            XCTFail("Expected the injected container failure")
        } catch {
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, previous.bundleIdentifier)
    }

    func test_syncFailureAfterDirectWriterDoesNotRestoreStaleConfiguration() {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let replacement = ManifoldConfiguration(
            bundleIdentifier: "com.manifoldkit.runtime-tests.newer-writer.\(UUID().uuidString)"
        )
        XCTAssertThrowsError(
            try ManifoldBootstrap(
                configuration: ManifoldConfiguration(
                    bundleIdentifier: "com.manifoldkit.runtime-tests.failing-owner.\(UUID().uuidString)"
                ),
                makeModelContainer: {
                    ManifoldConfiguration.shared = replacement
                    throw ForcedFailure()
                }
            )
        ) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier, replacement.bundleIdentifier)
    }

    func test_asyncBuild_emitsExistingMilestonesAndKeepsSecurityPoliciesLive() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                bundleIdentifier: "com.manifoldkit.runtime-tests.milestones.\(UUID().uuidString)",
                customHostTrustPolicy: .platformDefault,
                allowUnpinnedCredentialedHosts: true,
                networkPolicy: .unrestricted
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        var milestones: [RuntimeBootstrapMilestone] = []
        for await milestone in progress { milestones.append(milestone) }
        _ = try await task.value

        XCTAssertEqual(milestones, RuntimeBootstrapMilestone.allCases)

        var tightened = ManifoldConfiguration.shared
        tightened.customHostTrustPolicy = .requireExplicitPins
        tightened.allowUnpinnedCredentialedHosts = false
        tightened.networkPolicy = .allowlist(["allowed.example"])
        ManifoldConfiguration.shared = tightened

        XCTAssertEqual(ManifoldConfiguration.shared.customHostTrustPolicy, .requireExplicitPins)
        XCTAssertFalse(ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts)
        let blockedURL = try XCTUnwrap(URL(string: "https://blocked.example/api"))
        let blockedRequest = URLRequest(url: blockedURL)
        XCTAssertTrue(
            NetworkPolicyURLProtocol.canInit(with: blockedRequest),
            "The request guard must keep reading the tightened process-wide policy after bootstrap"
        )
    }

    private func assertConstructionInProgress(
        _ task: Task<ManifoldBootstrap, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Overlapping async construction must fail", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ManifoldBootstrapError,
                .constructionInProgress,
                file: file,
                line: line
            )
        }
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
        let session = ManifoldInference.ChatSession(title: "Wiring Identity Probe")
        try await runtime.persistence.insertSession(session)
        let descriptor = FetchDescriptor<PersistedChatSession>()
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
        var session = ManifoldInference.ChatSession(title: "Shared Session")
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
        let session = ManifoldInference.ChatSession(title: "Runtime Session")

        try await runtime.persistence.insertSession(session)

        let sessions = try await runtime.persistence.fetchSessions()
        XCTAssertEqual(sessions.map(\.id), [session.id])
    }

    // MARK: - RAG wiring parity

    /// Regression guard: a host using the async ``ManifoldBootstrap/build``
    /// splash path with a ``RAGConfiguration`` must get a runtime with RAG
    /// enabled, exactly like the synchronous `init`. Before this fix, `build()`
    /// had no `ragConfiguration:` parameter and silently produced a runtime
    /// with `ragService == nil` (retrieval disabled with no error or warning).
    func test_buildAndInit_haveIdenticalRAGWiringParity() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let ragConfiguration = RAGConfiguration(chunkSize: 1200, chunkOverlap: 100, topK: 3)

        // Synchronous init enables RAG.
        let viaInit = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "RAG Init",
                bundleIdentifier: "com.manifoldkit.runtime-tests.rag-init.\(UUID().uuidString)"
            ),
            ragConfiguration: ragConfiguration,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        XCTAssertNotNil(viaInit.ragService,
            "Synchronous init with a RAGConfiguration must enable RAG retrieval")

        // The async build() path must reach the same state.
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "RAG Build",
                bundleIdentifier: "com.manifoldkit.runtime-tests.rag-build.\(UUID().uuidString)"
            ),
            ragConfiguration: ragConfiguration,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let viaBuild = try await task.value
        XCTAssertNotNil(viaBuild.ragService,
            "build(ragConfiguration:) must enable RAG retrieval — parity with the synchronous init")
    }

    /// Existing `build()` callers that pass no `ragConfiguration:` must be
    /// unaffected: RAG stays disabled, matching the synchronous `init` default.
    func test_buildAndInit_defaultToRAGDisabled() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let viaInit = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "No RAG Init",
                bundleIdentifier: "com.manifoldkit.runtime-tests.norag-init.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        XCTAssertNil(viaInit.ragService,
            "init without a RAGConfiguration must leave RAG disabled")

        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "No RAG Build",
                bundleIdentifier: "com.manifoldkit.runtime-tests.norag-build.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let viaBuild = try await task.value
        XCTAssertNil(viaBuild.ragService,
            "build() without a RAGConfiguration must leave RAG disabled")
    }
}
