import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Regression coverage for ManifoldKit#2344: session-scripts mode completed
/// 30 "generations" in 1 second and reported `findings=0`, `exit 0` — because
/// nothing checked whether any generation actually ran to completion, so an
/// entirely inert campaign was indistinguishable from a genuinely clean soak.
///
/// The sabotage factory below hands back a `MockInferenceBackend` whose
/// `isModelLoaded` flag is `false` at generate-time even though the fuzz
/// harness's own bookkeeping believes the backend is loaded and ready — the
/// same shape of bug as the real MLX repro (a backend that *looks* wired up
/// to `SessionFuzzRunner` but fails every `generate()` call instantly,
/// producing valid-shaped-but-empty records at ~50x the physically possible
/// rate). It is intentionally NOT a fabrication of the exact MLX internals
/// (out of reach without a GPU + model in this test target) — it reproduces
/// the *observable contract* the issue describes: every turn fails
/// synchronously, near-instantly, with an empty/failed record, and no
/// detector flags it.
final class SessionFuzzRunnerInertGuardTests: XCTestCase {

    /// A `FuzzBackendFactory` that always returns the SAME `MockInferenceBackend`.
    /// When `healthy == false`, the backend's `isModelLoaded` is left `false`
    /// while the harness's own handle/lifecycle bookkeeping reports it as
    /// ready — `MockInferenceBackend.generate()` throws "No model loaded"
    /// synchronously in that state, so every turn fails instantly with an
    /// empty record, mirroring the reported symptom's observable shape.
    struct SabotageableFactory: FuzzBackendFactory {
        let backend: MockInferenceBackend

        init(healthy: Bool) {
            let mock = MockInferenceBackend()
            mock.tokensToYield = ["real", " ", "content"]
            mock.isModelLoaded = healthy
            self.backend = mock
        }

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "mock-model",
                modelURL: URL(string: "mock:mock-model")!,
                backendName: "mock",
                templateMarkers: nil
            )
        }
    }

    private func makeTempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-fuzz-inert-guard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A KV-reuse-shaped script: several independent `.send` turns plus a
    /// trailing `.regenerate`, mirroring `fuzz-mlx`'s `kvReuseScript()` (6
    /// turn-producing steps) closely enough to exercise the same accounting.
    private func kvReuseShapedScript() -> SessionScript {
        SessionScript(
            id: "inert-guard-probe",
            steps: [
                .send(text: "What is the boiling point of water at sea level in Celsius?"),
                .send(text: "Name the largest moon of Saturn."),
                .send(text: "In what year did the French Revolution begin?"),
                .send(text: "How many sides does a hexagon have?"),
                .send(text: "What is the chemical symbol for gold?"),
                .regenerate,
            ],
            systemPrompt: "You are a factual assistant."
        )
    }

    // MARK: - Sabotage: every generate() fails instantly, zero real work done

    func test_allTurnsFailingInstantly_isReportedAsInert() async throws {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 5,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            sessionScripts: true
        )
        let factory = SabotageableFactory(healthy: false)
        let runner = SessionFuzzRunner(config: config, factory: factory, scripts: [kvReuseShapedScript()])

        let start = ContinuousClock.now
        let report = await runner.run(reporter: TerminalReporter(quiet: true))
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(report.totalRuns, 5, "iteration budget should still be honored even though every turn fails")
        XCTAssertEqual(report.realCompletions, 0, "not one of the 30 turns should have reached phase==\"done\"")
        XCTAssertTrue(report.isInert, "a campaign with runs > 0 and realCompletions == 0 must be flagged inert")
        XCTAssertLessThan(
            elapsed, .seconds(2),
            "precondition: this sabotage must reproduce the 'impossibly fast' symptom, not accidentally do real work"
        )
    }

    // MARK: - Healthy counterpart: same script, working backend, NOT inert

    func test_healthyBackend_completesRealTurns_isNotInert() async throws {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 5,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            sessionScripts: true
        )
        let factory = SabotageableFactory(healthy: true)
        let runner = SessionFuzzRunner(config: config, factory: factory, scripts: [kvReuseShapedScript()])

        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 5)
        // 5 iterations * 6 turn-producing steps (5 sends + 1 regenerate) each.
        XCTAssertEqual(report.realCompletions, 30, "every send/regenerate step across all 5 iterations should complete for real")
        XCTAssertFalse(report.isInert, "a campaign that actually drove generation must never be flagged inert")
    }

    // MARK: - The guard's coverage boundary: does the rig find real anomalies?

    /// `isInert` only proves the rig can tell "did no work" from "did work".
    /// It says nothing about whether a WORKING rig still catches real bugs —
    /// that's a property of the detector suite, not this guard. This test
    /// sabotages the target differently: the backend generates real content
    /// (not inert, `isModelLoaded == true`, real token stream), but the
    /// content itself is broken — a repeating loop, the exact `LoopingDetector`
    /// class of bug this harness exists to catch (its doc comment cites
    /// "qwen3.5:4b looping inside `<think>` blocks until maxOutputTokens
    /// exhausts"). Confirms the rig still finds a genuine anomaly through the
    /// full session-scripts path once it's actually driving generation —
    /// `isInert == false` alone would not have proven that.
    func test_realButLoopingOutput_isCaughtAsAFinding() async throws {
        let outputDir = makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .mock,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            sessionScripts: true
        )
        let factory = SabotageableFactory(healthy: true)
        // Overwrite the default token script with a >100-char repeating unit —
        // `RepetitionDetector.looksLikeLooping` (backing `LoopingDetector`)
        // triggers on a 50+ char unit repeated back-to-back within the tail.
        let loopingPhrase = "This is a broken model stuck repeating the exact same sentence. "
        factory.backend.tokensToYield = Array(repeating: loopingPhrase, count: 6)
        let runner = SessionFuzzRunner(config: config, factory: factory, scripts: [kvReuseShapedScript()])

        let report = await runner.run(reporter: TerminalReporter(quiet: true))

        XCTAssertFalse(report.isInert, "precondition: this run must have done real work, not vacuously passed")
        XCTAssertGreaterThan(report.realCompletions, 0)
        XCTAssertGreaterThan(
            report.dedupedCount, 0,
            "a real, working-but-broken generation (looping output) must still be caught as a finding — " +
            "isInert only distinguishes 'no work' from 'work'; this proves the detector suite still catches " +
            "a genuine anomaly once work is happening"
        )
        XCTAssertTrue(
            report.perDetectorFlagRate.keys.contains("looping"),
            "the looping detector specifically should be the one that fired"
        )
    }
}
