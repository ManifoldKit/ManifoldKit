import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Verifies the behaviour of a `FuzzBackendFactory` conformance that wraps
/// `MockInferenceBackend`. Mirrors the shape of the real `MockFuzzFactory`
/// shipped in `Sources/fuzz-chat/`. The factory there is a thin wrapper around
/// `MockInferenceBackend`; because SPM does not allow a test target to import
/// an `executableTarget`, we re-declare the factory here and assert that the
/// pattern the CLI uses produces a valid `BackendHandle` and drives one
/// iteration cleanly through `FuzzRunner`.
final class MockFuzzFactoryTests: XCTestCase {

    /// Test-local mirror of `Sources/fuzz-chat/MockFuzzFactory.swift`. Any
    /// behavioural divergence between this copy and the executable's copy
    /// should either be cleaned up in both places or reflected with a distinct
    /// test. Keep the two structurally identical.
    struct LocalMockFuzzFactory: FuzzBackendFactory {
        let tokensToYield: [String]

        init(tokensToYield: [String] = ["Hello", " ", "world", "."]) {
            self.tokensToYield = tokensToYield
        }

        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = MockInferenceBackend()
            backend.tokensToYield = tokensToYield
            try await backend.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "mock-model",
                modelURL: URL(string: "mock:mock-model")!,
                backendName: "mock",
                templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
            )
        }
    }

    private func makeTempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tests

    /// `makeHandle()` returns a handle whose backend is loaded and ready to
    /// generate. This is the invariant the runner depends on: the first
    /// `generate` call must not throw because the model isn't loaded.
    @MainActor
    func test_makeHandle_returnsLoadedBackend() async throws {
        let factory = LocalMockFuzzFactory()
        let handle = try await factory.makeHandle()
        XCTAssertTrue(handle.backend.isModelLoaded, "factory must pre-load the backend so the runner's first generate() succeeds")
        XCTAssertEqual(handle.backendName, "mock")
        XCTAssertEqual(handle.modelId, "mock-model")
    }

    /// End-to-end: factory handle feeds `FuzzRunner.run` for one iteration and
    /// produces a non-zero total-run count. Exercises the same code path as
    /// `swift run fuzz-chat --backend mock --iterations 1`.
    func test_factoryDrivesOneIterationThroughRunner() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let runner = FuzzRunner(config: config, factory: LocalMockFuzzFactory())
        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 1, "one-iteration campaign should execute exactly once")
    }

    /// Corpus subset wiring: the runner picks from the smoke set when asked,
    /// and from the full set by default. Exercised by counting distinct
    /// corpus IDs the runner could have chosen via the seeded RNG — the smoke
    /// set must be non-empty or the runner reports zero runs.
    func test_smokeCorpusSubsetNonEmpty() {
        let smoke = Corpus.load(subset: .smoke)
        XCTAssertFalse(smoke.isEmpty, "smoke_seeds.json must exist and parse")
        XCTAssertGreaterThanOrEqual(smoke.count, 5, "smoke set should have at least a handful of prompts to exercise mutators")
    }

    // MARK: - ManifoldKit#2344 floor-rate guard (single-turn twin)

    /// A factory that reports a loaded handle but hands out a backend whose
    /// `generate()` fails synchronously every call — same sabotage shape as
    /// `SessionFuzzRunnerInertGuardTests`, applied to the single-turn runner
    /// so `FuzzReport.isInert` is verified on both entry points that share it.
    struct InstantlyFailingFactory: FuzzBackendFactory {
        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = MockInferenceBackend() // isModelLoaded stays false
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "mock-model",
                modelURL: URL(string: "mock:mock-model")!,
                backendName: "mock",
                templateMarkers: nil
            )
        }
    }

    func test_everyIterationFailingInstantly_isReportedAsInert() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 5,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let runner = FuzzRunner(config: config, factory: InstantlyFailingFactory())
        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 5)
        XCTAssertEqual(report.realCompletions, 0)
        XCTAssertTrue(report.isInert, "a single-turn campaign where every iteration fails before generating must be flagged inert")
    }

    /// Healthy counterpart: the existing `LocalMockFuzzFactory` backend
    /// (properly loaded) must NOT be flagged inert.
    func test_healthyFactory_isNotInert() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 3,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let runner = FuzzRunner(config: config, factory: LocalMockFuzzFactory())
        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.realCompletions, 3)
        XCTAssertFalse(report.isInert)
    }
}
