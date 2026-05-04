#if Fuzz
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatFuzz

/// Mirrors `MockFuzzFactoryTests` but wraps `ChaosBackend` instead. The factory
/// under test in `Sources/fuzz-chat/ChaosFuzzFactory.swift` is re-declared
/// here because SPM test targets cannot import executable targets.
final class ChaosFuzzFactoryTests: XCTestCase {

    struct LocalChaosFuzzFactory: FuzzBackendFactory {
        let mode: ChaosBackend.FailureMode
        let tokensToYield: [String]

        init(
            mode: ChaosBackend.FailureMode = .none,
            tokensToYield: [String] = ["Hello", " ", "world", "."]
        ) {
            self.mode = mode
            self.tokensToYield = tokensToYield
        }

        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = ChaosBackend(mode: mode, tokensToYield: tokensToYield)
            try await backend.loadModel(from: URL(string: "chaos:chaos-model")!, plan: .cloud())
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "chaos-model",
                modelURL: URL(string: "chaos:chaos-model")!,
                backendName: "chaos",
                templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
            )
        }
    }

    private func makeTempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaos-fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func test_makeHandle_returnsLoadedBackend() async throws {
        let factory = LocalChaosFuzzFactory()
        let handle = try await factory.makeHandle()
        XCTAssertTrue(handle.backend.isModelLoaded, "chaos factory must pre-load the backend")
        XCTAssertEqual(handle.backendName, "chaos")
    }

    /// Drives the runner with a chaos backend in happy-path mode. One iteration
    /// should complete without error and report a single run.
    func test_happyPathChaos_completesOneIteration() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .chaos,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let runner = FuzzRunner(config: config, factory: LocalChaosFuzzFactory())
        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 1)
    }

    /// Runs a chaos factory configured with a network-error failure mode so the
    /// runner exercises the error-path `EventRecorder.Capture` branch rather
    /// than the success branch. Verifies the runner doesn't crash when the
    /// stream throws partway.
    func test_chaosNetworkError_doesNotCrashRunner() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .chaos,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let factory = LocalChaosFuzzFactory(mode: .networkError(afterTokens: 1))
        let runner = FuzzRunner(config: config, factory: factory)
        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 1, "runner must absorb stream errors and still tally the iteration")
    }
}
#endif
