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

    /// `onTimeout` can perform real async cleanup before returning the
    /// fallback — proves `GenerationTimeout` doesn't just abandon the
    /// operation and hope; it gives callers a hook to actually stop it.
    func test_generationTimeout_onTimeout_canPerformAsyncCleanup() async {
        let cleanupRan = ManagedFlag()
        let result = await GenerationTimeout.run(
            .milliseconds(100),
            operation: {
                try? await Task.sleep(for: .seconds(30))
                return "operation-completed"
            },
            onTimeout: {
                await cleanupRan.set(true)
                return "timed-out"
            }
        )
        XCTAssertEqual(result, "timed-out")
        let ran = await cleanupRan.get()
        XCTAssertTrue(ran, "onTimeout's async cleanup must actually run before the fallback is returned")
    }

    private actor ManagedFlag {
        private var value = false
        func set(_ newValue: Bool) { value = newValue }
        func get() -> Bool { value }
    }

    /// Test-local mirror of `Sources/fuzz-chat/MockFuzzFactory.swift`,
    /// wrapping a caller-supplied `MockInferenceBackend` so the test can hold
    /// a reference to it (and its `tokenEmissionGate`/`stopCallCount`) after
    /// the runner is done with it.
    private struct GatedMockFactory: FuzzBackendFactory {
        let backend: MockInferenceBackend
        let backendName: String

        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "mock-model",
                modelURL: URL(string: "mock:mock-model")!,
                backendName: backendName,
                templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
            )
        }
    }

    /// The critical guarantee the reviewer flagged: `GenerationTimeout`
    /// abandoning the operation task is NOT enough on its own — a real
    /// in-flight generation keeps running against the backend unless
    /// something actually calls `stopGeneration()`. Uses `TokenEmissionGate`
    /// (never advanced) to hold the mock backend's stream open indefinitely,
    /// mirroring a truly hung local-backend generation, and asserts
    /// `FuzzRunner.runSingle`'s `onTimeout` really invokes
    /// `InferenceBackend.stopGeneration()` — not just that the iteration
    /// returns quickly.
    func test_localBackendHang_actuallyCallsStopGeneration() async throws {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["never emitted"]
        mock.tokenEmissionGate = TokenEmissionGate() // never advanced — first token blocks forever
        try await mock.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())

        let config = FuzzConfig(
            backend: .mock,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke,
            requestTimeout: 0.3
        )
        let runner = FuzzRunner(config: config, factory: GatedMockFactory(backend: mock, backendName: "mock"))

        let start = ContinuousClock.now
        let report = await runner.run(reporter: TerminalReporter(quiet: true))
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(report.totalRuns, 1)
        XCTAssertLessThan(elapsed, .seconds(5), "a permanently-gated stream must still be bounded by requestTimeout")
        XCTAssertGreaterThanOrEqual(
            mock.stopCallCount, 1,
            "onTimeout must call stopGeneration() on the backend, not just abandon the operation task"
        )
    }

    /// The cloud (`openai`-named) path is deliberately exempt from the
    /// wall-clock `GenerationTimeout` wrap — it already has its own
    /// transport-level idle timeout (which resets on activity), so wrapping
    /// it here too would additionally hard-cut a slow-but-continuously-
    /// streaming completion that would otherwise finish. Proven by driving a
    /// handle named "openai" through a stall that's shorter than
    /// `requestTimeout`... no — longer: the point is the iteration must NOT
    /// be cut short at `requestTimeout`, so this uses a stall a bit longer
    /// than `requestTimeout` and asserts the FULL stall duration elapsed
    /// (proving the wrap did not fire), not just `requestTimeout`.
    func test_openAINamedBackend_isExemptFromWallClockTimeout() async {
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
        // Backend is a ChaosBackend under the hood (any in-process backend
        // works for this test), but the HANDLE claims the "openai" identity —
        // FuzzRunner branches on `handle.backendName`, not the concrete type.
        let factory = StallingChaosFactory(stallDuration: .milliseconds(900))
        let runner = FuzzRunner(
            config: config,
            factory: NamedFactory(inner: factory, backendName: "openai")
        )

        let start = ContinuousClock.now
        _ = await runner.run(reporter: TerminalReporter(quiet: true))
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(850),
            "an 'openai'-named handle must run past requestTimeout (0.3s) uncut, since its transport-level idle timeout is the only bound applied to it"
        )
    }

    /// Wraps another factory's handle, overriding only `backendName` — lets
    /// a test drive any concrete backend under an arbitrary claimed identity.
    private struct NamedFactory: FuzzBackendFactory {
        let inner: any FuzzBackendFactory
        let backendName: String

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let handle = try await inner.makeHandle()
            return FuzzRunner.BackendHandle(
                backend: handle.backend,
                modelId: handle.modelId,
                modelURL: handle.modelURL,
                backendName: backendName,
                templateMarkers: handle.templateMarkers,
                memoryBudgetBytes: handle.memoryBudgetBytes
            )
        }
    }
}
