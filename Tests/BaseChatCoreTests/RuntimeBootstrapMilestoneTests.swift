import XCTest
import SwiftData
@testable import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference

@MainActor
final class RuntimeBootstrapMilestoneTests: XCTestCase {
    func test_build_emitsMilestonesInDeclarationOrder() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let (progress, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Milestone Order",
                bundleIdentifier: "com.basechatkit.milestone-tests.order.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        var collected: [RuntimeBootstrapMilestone] = []
        for await milestone in progress {
            collected.append(milestone)
        }
        _ = try await task.value

        XCTAssertEqual(collected, RuntimeBootstrapMilestone.allCases)
    }

    func test_build_completeMilestoneIsLast() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let (progress, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Complete Is Last",
                bundleIdentifier: "com.basechatkit.milestone-tests.last.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        var last: RuntimeBootstrapMilestone?
        for await milestone in progress {
            last = milestone
        }
        _ = try await task.value

        XCTAssertEqual(last, .complete)
    }

    func test_build_streamFinishesWhenMakeModelContainerThrows() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let (progress, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Failure Stream",
                bundleIdentifier: "com.basechatkit.milestone-tests.failure.\(UUID().uuidString)"
            ),
            makeModelContainer: { throw URLError(.cannotOpenFile) }
        )

        var collected: [RuntimeBootstrapMilestone] = []
        for await milestone in progress {
            collected.append(milestone)
        }

        XCTAssertFalse(collected.contains(.complete))

        do {
            _ = try await task.value
            XCTFail("task.value should have thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func test_build_throwingMakeModelContainer_restoresConfiguration() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let (_, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Rollback",
                bundleIdentifier: "com.basechatkit.milestone-tests.rollback.\(UUID().uuidString)"
            ),
            makeModelContainer: { throw URLError(.cannotOpenFile) }
        )

        do { _ = try await task.value } catch {}

        XCTAssertEqual(BaseChatConfiguration.shared.bundleIdentifier, originalConfiguration.bundleIdentifier)
    }

    func test_build_runtimeExposesInjectedInferenceServiceAndContainer() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let injectedService = InferenceService()
        let prebuiltContainer = try ModelContainerFactory.makeInMemoryContainer()

        let (progress, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Wiring Identity",
                bundleIdentifier: "com.basechatkit.milestone-tests.wiring.\(UUID().uuidString)"
            ),
            inferenceService: injectedService,
            makeModelContainer: { prebuiltContainer }
        )

        for await _ in progress {}
        let runtime = try await task.value

        XCTAssertTrue(runtime.inferenceService === injectedService)
        XCTAssertTrue(runtime.modelContainer === prebuiltContainer)
    }

    func test_fractionComplete_isStrictlyIncreasing() {
        let fractions = RuntimeBootstrapMilestone.allCases.map(\.fractionComplete)
        for (index, fraction) in fractions.dropLast().enumerated() {
            XCTAssertLessThan(fraction, fractions[index + 1])
        }
        XCTAssertEqual(fractions.last, 1.0)
    }

    func test_fractionComplete_isWithinUnitRange() {
        for milestone in RuntimeBootstrapMilestone.allCases {
            XCTAssertGreaterThanOrEqual(milestone.fractionComplete, 0.0)
            XCTAssertLessThanOrEqual(milestone.fractionComplete, 1.0)
        }
    }

    func test_build_persistenceRoundTrip() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let (progress, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Build Persistence",
                bundleIdentifier: "com.basechatkit.milestone-tests.persistence.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        for await _ in progress {}
        let runtime = try await task.value

        let session = ChatSessionRecord(title: "Milestone Build Session")
        try await runtime.persistence.insertSession(session)

        let fetched = try await runtime.persistence.fetchSessions()
        XCTAssertTrue(fetched.contains(where: { $0.id == session.id }))
    }
}
