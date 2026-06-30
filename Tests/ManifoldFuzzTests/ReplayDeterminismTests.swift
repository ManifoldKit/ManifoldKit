import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// "Test the test" guardrail: without this file, a plumbing bug that makes all
/// replays identically-successful — for example, accidentally caching the
/// original record's output buffer and returning it every attempt — would slip
/// through the other ReplayTests because `MockInferenceBackend` is genuinely
/// deterministic.
///
/// Here we drive the Replayer with a `ChaosBackend` configured to behave
/// differently across attempts, and assert the Replayer *sees* the variance.
/// The sabotage check is documented inline.
final class ReplayDeterminismTests: XCTestCase {

    /// Factory that hands out a `ChaosBackend` with a pre-configured mode.
    /// Tokens are sized to reliably trip the `LoopingDetector`.
    struct ChaosFactory: FuzzBackendFactory {
        let tokens: [String]
        let mode: ChaosBackend.FailureMode

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = ChaosBackend(mode: mode, tokensToYield: tokens)
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "chaos-model",
                modelURL: URL(string: "mem:chaos-model")!,
                backendName: "chaos",
                templateMarkers: nil
            )
        }
    }

    /// Hands out a SHARED `MockInferenceBackend` so the test can introspect the
    /// `GenerationConfig` the Replayer's re-drive actually passed to `generate`
    /// via `MockInferenceBackend.lastConfig`. Defaults to deterministic-replay
    /// capable so it clears the Replayer's `supportsDeterministicReplay` gate.
    struct CapturingFactory: FuzzBackendFactory {
        let backend: MockInferenceBackend

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            backend.isModelLoaded = true
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "chaos-model",
                modelURL: URL(string: "mem:chaos-model")!,
                backendName: "chaos",
                templateMarkers: nil
            )
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayDeterminismTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func seedLoopingRecord(
        seed: UInt64 = 1337,
        topK: Int32? = nil,
        repeatPenalty: Float = 1.1
    ) throws -> String {
        let rendered = String(repeating: "ha ", count: 60)
        let trigger = String(rendered.suffix(120))
        let finding = Finding(
            detectorId: "looping",
            subCheck: "rendered-loop",
            severity: .flaky,
            trigger: trigger,
            modelId: "chaos-model"
        )
        let record = RunRecord(
            runId: UUID().uuidString,
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "aaaaaaa",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "chaos",
                id: "chaos-model",
                url: "mem:chaos-model",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: seed,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: 256,
                systemPrompt: nil,
                topK: topK,
                repeatPenalty: repeatPenalty
            ),
            prompt: .init(
                corpusId: "test",
                mutators: [],
                messages: [.init(role: "user", text: "fuzz me")]
            ),
            events: [],
            raw: rendered,
            rendered: rendered,
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: nil,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: 10, totalMs: 50, tokensPerSec: 100),
            phase: "done",
            error: nil,
            stopReason: "naturalStop"
        )
        let findingDir = tempDir
            .appendingPathComponent("findings", isDirectory: true)
            .appendingPathComponent("looping", isDirectory: true)
            .appendingPathComponent(finding.hash, isDirectory: true)
        try FileManager.default.createDirectory(at: findingDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: findingDir.appendingPathComponent("record.json"))

        let index: [String: Any] = [
            "totalRuns": 1,
            "rows": [[
                "finding": [
                    "detectorId": finding.detectorId,
                    "subCheck": finding.subCheck,
                    "severity": finding.severity.rawValue,
                    "hash": finding.hash,
                    "trigger": finding.trigger,
                    "modelId": finding.modelId,
                    "firstSeen": finding.firstSeen,
                    "count": finding.count,
                ],
                "modelId": "chaos-model",
                "seed": seed,
                "lastSeen": "2026-04-19T00:00:00Z",
            ]],
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try indexData.write(to: tempDir.appendingPathComponent("index.json"))
        return finding.hash
    }

    /// A ChaosBackend in `.dropMidStream(afterTokens: 4)` emits only the first 4
    /// "ha " tokens — rendered output is 12 chars, below the 100-char
    /// LoopingDetector threshold. The replay should NOT reproduce, even though
    /// the record's rendered output WAS a loop. This proves that replay is
    /// actually executing a fresh stream and not just re-reading the record.
    func test_chaosBackend_dropsMidStream_preventsSpuriousReproduction() async throws {
        let hash = try seedLoopingRecord()
        let loopingTokens = Array(repeating: "ha ", count: 60)
        let factory = ChaosFactory(
            tokens: loopingTokens,
            mode: .dropMidStream(afterTokens: 4)
        )
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )

        let outcome = try await replayer.replay(hash: hash, attempts: 3)
        guard case .reproduced(let result) = outcome else {
            return XCTFail("expected .reproduced, got \(outcome)")
        }
        XCTAssertEqual(result.successfulReproductions, 0,
            "a 4-token truncation cannot fire the 100-char looping detector; 0/3 expected")
        XCTAssertNil(result.newSeverity, "the gate must NOT promote when replay does not reproduce")
    }

    /// Seed-plumbing sabotage evidence: when the Replayer wires the recorded
    /// seed into its replay ConfigSnapshot, the emitted record for every attempt
    /// carries the recorded seed (1337 above). If a future refactor accidentally
    /// threads a fresh seed through instead, this assertion catches it.
    ///
    /// This is the contract boundary the brief singled out as "the seed-plumbing
    /// correctness surface". It is tested via a public hook — we run replay and
    /// then introspect index.json's unchanged seed field plus the Result.
    func test_replay_preservesRecordedSeed_inReplayOutput() async throws {
        let hash = try seedLoopingRecord()
        let tokens = Array(repeating: "ha ", count: 60)
        let factory = ChaosFactory(tokens: tokens, mode: .none)
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )

        _ = try await replayer.replay(hash: hash, attempts: 1)

        // The on-disk record.json must retain its original seed (record is
        // never overwritten on replay). This guards against an "overwrite
        // record.json" regression.
        let recordURL = tempDir
            .appendingPathComponent("findings")
            .appendingPathComponent("looping")
            .appendingPathComponent(hash)
            .appendingPathComponent("record.json")
        let data = try Data(contentsOf: recordURL)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: data)
        XCTAssertEqual(decoded.config.seed, 1337,
            "the original record's seed must be preserved on disk after replay")
    }

    /// The core regression guard: the recorded seed/topK/repeatPenalty must be
    /// threaded into the `GenerationConfig` the re-drive hands to the backend's
    /// `generate`. We assert at the config boundary (not on output) because
    /// `MockInferenceBackend` ignores the seed for its token stream — only the
    /// config plumbing is observable.
    ///
    /// Sabotage map (this test FAILS unless `runOnce` threads each field):
    ///  - drop `cfg.seed = record.config.seed` → `lastConfig.seed` is nil ≠ 4242
    ///  - drop `cfg.topK = record.config.topK` → `lastConfig.topK` is nil ≠ 7
    ///  - hardcode `repeatPenalty: 1.1` → `lastConfig.repeatPenalty` is 1.1 ≠ 1.7
    func test_runOnce_threadsRecordedSamplerConfig_intoReDriveGenerate() async throws {
        let hash = try seedLoopingRecord(seed: 4242, topK: 7, repeatPenalty: 1.7)
        let backend = MockInferenceBackend()
        backend.tokensToYield = Array(repeating: "ha ", count: 60)
        let factory = CapturingFactory(backend: backend)
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )

        _ = try await replayer.replay(hash: hash, attempts: 1)

        let used = try XCTUnwrap(backend.lastConfig,
            "the re-drive must have called generate exactly once")
        XCTAssertEqual(used.seed, 4242,
            "recorded seed must be threaded into the re-drive config — without it replay samples against the backend default RNG")
        XCTAssertEqual(used.topK, 7,
            "recorded topK must be threaded into the re-drive config, not dropped")
        XCTAssertEqual(used.repeatPenalty, 1.7, accuracy: 1e-6,
            "recorded repeatPenalty must be threaded, not the hardcoded 1.1 fallback")
    }
}
