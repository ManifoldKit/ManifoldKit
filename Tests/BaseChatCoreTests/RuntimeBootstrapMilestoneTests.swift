import XCTest
import SwiftData
@testable import BaseChatCore
@testable import BaseChatInference

@MainActor
final class RuntimeBootstrapMilestoneTests: XCTestCase {

    // MARK: - Milestone ordering

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

        let expected = RuntimeBootstrapMilestone.allCases
        XCTAssertEqual(collected, expected,
            "Milestones must be emitted in CaseIterable declaration order")
    }

    // Sabotage check: comment out one `continuation.yield(...)` call in
    // `BaseChatRuntime.build` and this test fails with a count mismatch.

    // MARK: - Complete is last

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

        XCTAssertEqual(last, .complete,
            ".complete must be the final milestone before the stream finishes")
    }

    // MARK: - Stream finishes before task throws on failure

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

        // The stream must finish (not hang) even when bootstrap throws.
        XCTAssertFalse(collected.contains(.complete),
            ".complete must not be emitted when bootstrap fails")

        // The task must rethrow the error.
        do {
            _ = try await task.value
            XCTFail("task.value should have thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: - Configuration rollback on failure

    func test_build_throwingMakeModelContainer_restoresConfiguration() async throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let distinctBundleIdentifier = "com.basechatkit.milestone-tests.rollback.\(UUID().uuidString)"
        let (_, task) = BaseChatRuntime.build(
            configuration: BaseChatConfiguration(
                appName: "Rollback",
                bundleIdentifier: distinctBundleIdentifier
            ),
            makeModelContainer: { throw URLError(.cannotOpenFile) }
        )

        do { _ = try await task.value } catch {}

        XCTAssertEqual(
            BaseChatConfiguration.shared.bundleIdentifier,
            originalConfiguration.bundleIdentifier,
            "build must restore BaseChatConfiguration.shared when bootstrap fails"
        )
    }

    // MARK: - Runtime wiring identity

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

        XCTAssertTrue(runtime.inferenceService === injectedService,
            "build must use the injected InferenceService instance")
        XCTAssertTrue(runtime.modelContainer === prebuiltContainer,
            "build must use the ModelContainer returned by makeModelContainer")
    }

    // MARK: - fractionComplete coverage

    func test_fractionComplete_isStrictlyIncreasing() {
        let fractions = RuntimeBootstrapMilestone.allCases.map(\.fractionComplete)
        for (i, fraction) in fractions.dropLast().enumerated() {
            XCTAssertLessThan(fraction, fractions[i + 1],
                "fractionComplete must strictly increase across milestone cases")
        }
        XCTAssertEqual(fractions.last, 1.0,
            ".complete.fractionComplete must equal 1.0")
    }

    func test_fractionComplete_isWithinUnitRange() {
        for milestone in RuntimeBootstrapMilestone.allCases {
            XCTAssertGreaterThanOrEqual(milestone.fractionComplete, 0.0)
            XCTAssertLessThanOrEqual(milestone.fractionComplete, 1.0)
        }
    }

    // MARK: - Persistence round-trip via build

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
        XCTAssertTrue(fetched.contains(where: { $0.id == session.id }),
            "Session inserted through build runtime must be fetchable via the same runtime")
    }
}
