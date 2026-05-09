import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldTestSupport

/// Thread-safe value collector for `@Sendable` progress handler closures.
private actor ProgressCollector {
    private(set) var values: [Double] = []
    private(set) var callCount: Int = 0

    func record(_ value: Double) {
        values.append(value)
        callCount += 1
    }
}

/// Verifies the ``LoadProgressReporting`` protocol contract using ``MockLoadProgressBackend``.
///
/// These tests confirm the mock is self-consistent and that the protocol's handler
/// install/clear/deliver lifecycle works as specified. They do **not** verify that
/// ``LlamaBackend`` or ``MLXBackend`` implement the protocol correctly — real backend
/// coverage requires hardware and lives in ``ManifoldMLXIntegrationTests`` and
/// ``ManifoldE2ETests``.
final class LoadProgressReportingContractTests: XCTestCase {

    private let modelURL = URL(fileURLWithPath: "/tmp/fake-model")

    // MARK: - 1. Handler receives values during loadModel

    func test_handler_isCalledDuringLoad() async throws {
        let backend = MockLoadProgressBackend(progressValuesToEmit: [0.0, 0.5, 1.0])
        let collector = ProgressCollector()

        backend.setLoadProgressHandler { value in
            await collector.record(value)
        }

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let count = await collector.callCount
        XCTAssertGreaterThan(count, 0, "Handler must be called at least once during loadModel")
    }

    // MARK: - 2. All delivered values are in [0.0, 1.0]

    func test_handler_receivesValuesInRange() async throws {
        let backend = MockLoadProgressBackend(progressValuesToEmit: [0.0, 0.25, 0.75, 1.0])
        let collector = ProgressCollector()

        backend.setLoadProgressHandler { value in
            await collector.record(value)
        }

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let received = await collector.values
        XCTAssertFalse(received.isEmpty, "At least one progress value must be delivered")
        for value in received {
            XCTAssertGreaterThanOrEqual(value, 0.0, "Progress value \(value) is below 0.0")
            XCTAssertLessThanOrEqual(value, 1.0, "Progress value \(value) exceeds 1.0")
        }
    }

    // MARK: - 3. Clearing the handler suppresses all calls

    func test_nilHandler_suppressesAllCalls() async throws {
        let backend = MockLoadProgressBackend(progressValuesToEmit: [0.0, 0.5, 1.0])
        let collector = ProgressCollector()

        // Install then immediately clear.
        backend.setLoadProgressHandler { value in await collector.record(value) }
        backend.setLoadProgressHandler(nil)

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let count = await collector.callCount
        XCTAssertEqual(count, 0,
            "After setLoadProgressHandler(nil), handler must never be called during loadModel")
    }

    // MARK: - Sabotage check (verify tests are sensitive)

    // To confirm test 1 would catch a broken implementation:
    // Temporarily remove the `await handler?(value)` call in
    // `MockLoadProgressBackend.loadModel` — test_handler_isCalledDuringLoad
    // must fail with "Handler must be called at least once".
    // Remove the sabotage before committing.
}
