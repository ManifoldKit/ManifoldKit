@preconcurrency import XCTest
import Foundation
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - RuntimeScenarioRunnerTests

/// Tests for ``RuntimeScenarioRunner`` in `.scripted` mode.
///
/// Every test here uses the hermetic ``RuntimeScenarioRunner/RunMode/scripted``
/// mode and a ``ScriptedGenerationBackend`` — no network, no real model, no
/// SwiftData stack.
@MainActor
final class RuntimeScenarioRunnerTests: XCTestCase {

    // MARK: - E2E matrix gate

    /// Runs every registered scenario in `.scripted` mode and asserts the
    /// structural subsequence. This is the CI matrix gate: a new scenario
    /// added to ``RuntimeScenarioRegistry`` is automatically exercised here.
    func test_allRegisteredScenarios_passInScriptedMode() async throws {
        for scenario in RuntimeScenarioRegistry.all {
            let result = try await RuntimeScenarioRunner.run(scenario)
            RuntimeScenarioRunner.assert(result: result)
        }
    }

    // MARK: - Per-scenario assertions

    /// The basic token stream scenario produces a trace containing the
    /// expected stream lifecycle kinds.
    func test_basicTokenStream_traceContainsExpectedKinds() async throws {
        let result = try await RuntimeScenarioRunner.run(.basicTokenStream)

        XCTAssertEventSubsequence(
            result.trace.events,
            contains: [.streamStarted, .tokenEmitted, .streamFinished]
        )
    }

    /// A backend that emits a `kvCacheReuse` advisory before tokens must not
    /// abort generation — the runtime passes through to `streamFinished`.
    func test_kvCacheReuseAdvisory_completesWithoutError() async throws {
        let result = try await RuntimeScenarioRunner.run(.kvCacheReuseAdvisory)

        XCTAssertTrue(result.subsequencePassed, result.subsequenceFailureReason ?? "subsequence failed")
        let errorKinds = result.trace.kinds.filter { $0 == .errorRaised }
        XCTAssertTrue(errorKinds.isEmpty, "Expected no errorRaised events, got \(errorKinds.count)")
    }

    /// A backend that emits a `diagnosticThrottle` advisory before tokens must
    /// not abort generation — the runtime treats the advisory as informational.
    func test_throttleAdvisory_completesWithoutError() async throws {
        let result = try await RuntimeScenarioRunner.run(.diagnosticThrottleAdvisory)

        XCTAssertTrue(result.subsequencePassed, result.subsequenceFailureReason ?? "subsequence failed")
        let errorKinds = result.trace.kinds.filter { $0 == .errorRaised }
        XCTAssertTrue(errorKinds.isEmpty, "Expected no errorRaised events, got \(errorKinds.count)")
    }

    /// A two-turn scenario must contain two complete stream lifecycles.
    func test_multiTurnConversation_twoFullLifecycles() async throws {
        let result = try await RuntimeScenarioRunner.run(.multiTurnConversation)

        let startedCount = result.trace.kinds.filter { $0 == .streamStarted }.count
        let finishedCount = result.trace.kinds.filter { $0 == .streamFinished }.count

        XCTAssertEqual(startedCount, 2, "Expected 2 streamStarted events, got \(startedCount)")
        XCTAssertEqual(finishedCount, 2, "Expected 2 streamFinished events, got \(finishedCount)")
    }

    // MARK: - Registry integrity

    /// All scenario IDs in the registry must be unique — duplicate IDs would
    /// make tests report the wrong scenario on failure and confuse the demo picker.
    func test_registry_hasNoIDCollisions() {
        let ids = RuntimeScenarioRegistry.all.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(
            ids.count,
            uniqueIDs.count,
            "Duplicate IDs detected: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })"
        )
    }

    // MARK: - JSONL trace persistence

    /// Running a scenario and saving the trace produces a non-empty JSONL file.
    /// Exercises the ``ConversationEventTrace/save(to:)`` path end-to-end.
    func test_result_traceCanBeSavedAsJSONL() async throws {
        let result = try await RuntimeScenarioRunner.run(.basicTokenStream)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p3-trace-\(UUID().uuidString).jsonl")
        do {
            try result.trace.save(to: url)
        } catch {
            XCTFail("trace.save(to:) threw: \(error)")
            return
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        XCTAssertTrue(exists, "JSONL trace file was not created at \(url.path)")

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(content.isEmpty, "JSONL trace file is empty")
        } catch {
            XCTFail("Could not read trace file: \(error)")
        }

        // Clean up the temp file; ignore errors — test artifacts are benign.
        try? FileManager.default.removeItem(at: url)
    }
}
