import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Before this PR, only the OpenAI cloud fuzz path had any per-request
/// timeout (`OpenAIFuzzFactory.requestTimeout`, enforced at the HTTP
/// transport layer); local backends (Ollama, Foundation, mock, chaos)
/// generated in-process with no bound at all, so a hung generation stalled
/// the whole campaign forever. These tests drive a stalling `ChaosBackend`
/// through the real `FuzzRunner`/`FuzzConfig.requestTimeout` wiring and prove
/// the iteration is bounded regardless of backend.
final class LocalBackendGenerationTimeoutTests: XCTestCase {

    /// Test-local mirror of `Sources/fuzz-chat/ChaosFuzzFactory.swift` (a test
    /// target cannot import an executableTarget — see `MockFuzzFactoryTests`
    /// for the same pattern). Produces a fresh stalling `ChaosBackend` per
    /// `makeHandle()` call.
    private struct StallingChaosFactory: FuzzBackendFactory {
        let stallDuration: Duration

        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = ChaosBackend(
                mode: .burstThenStall(burstSize: 0, stallDuration: stallDuration),
                tokensToYield: ["Hello", " ", "world", "."]
            )
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "chaos-model",
                modelURL: URL(string: "mock:chaos-model")!,
                backendName: "chaos",
                templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
            )
        }
    }

    private func makeTempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-backend-timeout-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A local backend that stalls for far longer than `requestTimeout`
    /// still produces a record within the timeout window (not the stall
    /// duration), tagged as a timeout rather than silently hanging the
    /// campaign forever.
    func test_localBackendHang_isBoundedByRequestTimeout() async {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .chaos,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke,
            requestTimeout: 0.3
        )
        let factory = StallingChaosFactory(stallDuration: .seconds(30))
        let runner = FuzzRunner(config: config, factory: factory)

        let start = ContinuousClock.now
        let report = await runner.run(reporter: TerminalReporter(quiet: true))
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(report.totalRuns, 1)
        XCTAssertLessThan(
            elapsed,
            .seconds(10),
            "a single iteration must not wait anywhere near the 30s stall — GenerationTimeout should abandon it at ~0.3s"
        )
    }

    /// `GenerationTimeout` itself: the fallback fires and the operation is
    /// abandoned (not awaited to completion) once the timeout elapses.
    func test_generationTimeout_firesFallbackWithoutWaitingForOperation() async {
        let start = ContinuousClock.now
        let result = await GenerationTimeout.run(
            .milliseconds(100),
            operation: {
                try? await Task.sleep(for: .seconds(30))
                return "operation-completed"
            },
            onTimeout: { "timed-out" }
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(result, "timed-out")
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// Happy path: an operation that finishes before the timeout returns its
    /// real value, not the fallback.
    func test_generationTimeout_returnsOperationResultWhenFast() async {
        let result = await GenerationTimeout.run(
            .seconds(5),
            operation: { "operation-completed" },
            onTimeout: { "timed-out" }
        )
        XCTAssertEqual(result, "operation-completed")
    }
}
