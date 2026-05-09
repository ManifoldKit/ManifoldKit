#if Fuzz
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Verifies `FuzzRunner(config:factory:)` wires a `FuzzBackendFactory`
/// conformance through to the first iteration and surfaces factory errors.
final class FuzzBackendFactoryTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal `FuzzBackendFactory` that returns a pre-built handle. Mirrors the
    /// example in the issue brief — used by the happy-path test.
    struct StubFactory: FuzzBackendFactory {
        let handle: FuzzRunner.BackendHandle
        func makeHandle() async throws -> FuzzRunner.BackendHandle { handle }
    }

    /// Throws instead of producing a handle — exercises the runner's error path.
    struct FailingFactory: FuzzBackendFactory {
        struct BoomError: Error, Equatable {}
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            throw BoomError()
        }
    }

    private func makeConfig(outputDir: URL) -> FuzzConfig {
        FuzzConfig(
            backend: .ollama,
            minutes: nil,
            iterations: 1,
            seed: 42,
            modelHint: nil,
            detectorFilter: nil,
            outputDir: outputDir,
            calibrate: false,
            quiet: true
        )
    }

    private func makeHandle() -> FuzzRunner.BackendHandle {
        FuzzRunner.BackendHandle(
            backend: MockInferenceBackend(),
            modelId: "stub-model",
            modelURL: URL(string: "stub:stub-model")!,
            backendName: "stub",
            templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        )
    }

    private func makeTempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tests

    /// Happy path: the runner pulls a handle from the factory and runs at
    /// least one iteration.
    func test_factoryProducesHandle_runnerCompletesOneIteration() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let factory = StubFactory(handle: makeHandle())
        let runner = FuzzRunner(config: makeConfig(outputDir: outputDir), factory: factory)
        let reporter = TerminalReporter(quiet: true)

        let report = await runner.run(reporter: reporter)

        // One iteration ran => the factory was invoked and the handle wired through.
        XCTAssertEqual(report.totalRuns, 1, "runner should execute the configured iteration after obtaining a handle from the factory")
    }

    /// Default protocol extension: `teardown()` must compile and be a no-op
    /// for factories that don't override it. Guards against the extension being
    /// accidentally removed or miscompiled.
    func test_defaultTeardown_isNoOp() async throws {
        let factory = StubFactory(handle: makeHandle())
        await factory.teardown()  // should be a no-op
        // If we reach here without crashing, the test passes.
    }

    /// Failure path: the runner surfaces a factory error as a zero-run report
    /// rather than crashing. Mirrors the previous closure-based behaviour.
    func test_factoryThrows_runnerReportsZeroRuns() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let runner = FuzzRunner(config: makeConfig(outputDir: outputDir), factory: FailingFactory())
        let reporter = TerminalReporter(quiet: true)

        let report = await runner.run(reporter: reporter)

        XCTAssertEqual(report.totalRuns, 0, "runner must surface a factory error as a zero-run report")
        XCTAssertTrue(report.findings.isEmpty)
    }
}
#endif
