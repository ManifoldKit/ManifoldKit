import XCTest
@testable import BaseChatCore
@testable import BaseChatInference

@MainActor
final class BaseChatRuntimeTests: XCTestCase {

    func test_init_installsConfigurationBeforeBuildingModelContainer() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let bundleIdentifier = "com.basechatkit.runtime-tests.\(UUID().uuidString)"
        var bundleIdentifierSeenDuringContainerBuild: String?

        _ = try BaseChatRuntime(
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
        let runtime = try BaseChatRuntime(
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
            try BaseChatRuntime(
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

    func test_persistence_roundTripsSessionsThroughRuntimeProvider() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let runtime = try BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "Persistence Round Trip",
                bundleIdentifier: "com.basechatkit.runtime-tests.persistence"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let session = ChatSessionRecord(title: "Runtime Session")

        try runtime.persistence.insertSession(session)

        XCTAssertEqual(try runtime.persistence.fetchSessions().map(\.id), [session.id])
    }
}
