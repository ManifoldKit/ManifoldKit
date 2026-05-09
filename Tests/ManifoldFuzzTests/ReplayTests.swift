#if Fuzz
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Unit tests for `Replayer`. Use stub factories + injected git/model-hash
/// resolvers so we don't shell out or touch a real model file.
final class ReplayTests: XCTestCase {

    // MARK: - Test fixtures

    /// Produces a handle whose backend is a freshly-configured `MockInferenceBackend`.
    /// The token list is supplied at construction so each test can tune the
    /// response separately. Real factories (`OllamaFuzzFactory`) call
    /// `loadModel` before returning the handle — we replicate that here so
    /// replay's `generate` doesn't throw "No model loaded".
    struct StubFactory: FuzzBackendFactory {
        let tokens: [String]

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = MockInferenceBackend()
            backend.tokensToYield = tokens
            backend.isModelLoaded = true
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "stub-model",
                modelURL: URL(string: "mem:stub-model")!,
                backendName: "stub",
                templateMarkers: nil
            )
        }
    }

    /// Factory that explicitly opts out of deterministic replay. The model id
    /// is set to `cloud-model` so the Replayer's output (which quotes the
    /// record's backend field) is predictable — the record was stored with
    /// backend "stub-model" but the Replayer reports `record.model.backend`,
    /// not the factory's handle id.
    struct NonDeterministicFactory: FuzzBackendFactory {
        var supportsDeterministicReplay: Bool { false }
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = MockInferenceBackend()
            backend.isModelLoaded = true
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "cloud-model",
                modelURL: URL(string: "cloud:x")!,
                backendName: "cloud",
                templateMarkers: nil
            )
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a record.json + index.json pair to a findings subfolder shaped the
    /// way `FindingsSink` writes it, so the Replayer's resolver has something to
    /// find. Returns the finding hash so tests can replay by it.
    @discardableResult
    private func seedRecord(
        detectorId: String = "looping",
        schemaVersion: Int = RunRecord.currentSchema,
        packageGitRev: String = "aaaaaaa",
        fileSHA256: String? = nil,
        rendered: String,
        thinkingRaw: String = "",
        subCheck: String = "rendered-loop",
        trigger: String,
        severity: Severity = .flaky
    ) throws -> String {
        let finding = Finding(
            detectorId: detectorId,
            subCheck: subCheck,
            severity: severity,
            trigger: trigger,
            modelId: "stub-model"
        )
        let record = RunRecord(
            schemaVersion: schemaVersion,
            runId: UUID().uuidString,
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: packageGitRev,
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "stub",
                id: "stub-model",
                url: "mem:stub-model",
                fileSHA256: fileSHA256,
                tokenizerHash: nil
            ),
            config: .init(seed: 42, temperature: 0.0, topP: 1.0, maxTokens: 256, systemPrompt: nil),
            prompt: .init(
                corpusId: "test",
                mutators: [],
                messages: [.init(role: "user", text: "replay me")]
            ),
            events: [],
            raw: rendered,
            rendered: rendered,
            thinkingRaw: thinkingRaw,
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
            .appendingPathComponent(detectorId, isDirectory: true)
            .appendingPathComponent(finding.hash, isDirectory: true)
        try FileManager.default.createDirectory(at: findingDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recordData = try encoder.encode(record)
        try recordData.write(to: findingDir.appendingPathComponent("record.json"))

        // Minimal index.json so promotion has something to mutate.
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
                "modelId": "stub-model",
                "seed": 42,
                "lastSeen": "2026-04-19T00:00:00Z",
            ]],
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try indexData.write(to: tempDir.appendingPathComponent("index.json"))

        return finding.hash
    }

    /// Builds a looping-detector-flagging token burst: 120 chars of "ha " so
    /// `RepetitionDetector.looksLikeLooping` fires when replayed.
    private func loopingTokens() -> [String] {
        Array(repeating: "ha ", count: 60)
    }

    /// Trigger string looping detector will emit — see LoopingDetector.swift
    /// (`trigger: String(r.raw.suffix(120))`).
    private func loopingTrigger() -> String {
        String(String(repeating: "ha ", count: 60).suffix(120))
    }

    // MARK: - Resolver

    func test_replay_resolvesHash_fromFindingsDir() async throws {
        let hash = try seedRecord(rendered: "stub", trigger: "hi")
        let factory = StubFactory(tokens: [])
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )
        XCTAssertNotNil(replayer.resolveRecordURL(hash: hash))
        XCTAssertNil(replayer.resolveRecordURL(hash: "ffffffffffff"), "missing hashes return nil")
    }

    func test_replay_recordNotFound_returnsRecordNotFound() async throws {
        let factory = StubFactory(tokens: [])
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )
        let outcome = try await replayer.replay(hash: "deadbeefdead")
        XCTAssertEqual(outcome, .recordNotFound)
    }

    // MARK: - Drift

    func test_replay_refusesOnGitDrift_unlessForce() async throws {
        let hash = try seedRecord(
            packageGitRev: "7076c6f",
            rendered: "stub",
            trigger: "hi"
        )
        let factory = StubFactory(tokens: ["stub"])
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "fa9e236" },
            modelHashResolver: { _ in nil }
        )

        // Without --force: refusal with a DriftReport.
        let refused = try await replayer.replay(hash: hash)
        if case .driftRefused(let report) = refused {
            XCTAssertEqual(report.recordedGitRev, "7076c6f")
            XCTAssertEqual(report.currentGitRev, "fa9e236")
            XCTAssertTrue(report.gitDrifted)
        } else {
            XCTFail("expected .driftRefused, got \(refused)")
        }

        // With --force: replay still runs. Whether the finding reproduces is
        // irrelevant to this test — the point is no refusal.
        let forced = try await replayer.replay(hash: hash, force: true)
        if case .reproduced(let result) = forced {
            XCTAssertNotNil(result.drift, "forced-through drift must be reported on the Result")
        } else {
            XCTFail("expected .reproduced under --force, got \(forced)")
        }
    }

    // MARK: - Schema

    func test_replay_refusesOnSchemaFromFuture() async throws {
        let hash = try seedRecord(
            schemaVersion: 99,
            rendered: "stub",
            trigger: "hi"
        )
        let factory = StubFactory(tokens: ["stub"])
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: factory,
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )
        let outcome = try await replayer.replay(hash: hash)
        XCTAssertEqual(outcome, .schemaUnsupported(99))
    }

    // MARK: - Reproduce rate

    func test_replay_reportsReproduceRate_whenLoopingDetectorFires() async throws {
        // Loop pattern triggers LoopingDetector: rendered repeated "ha " exceeds
        // the 100-char threshold and looksLikeLooping is true.
        let hash = try seedRecord(
            rendered: String(repeating: "ha ", count: 60),
            trigger: loopingTrigger()
        )
        let factory = StubFactory(tokens: loopingTokens())
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
        XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(result.successfulReproductions, 3, "deterministic MockInferenceBackend must reproduce 3/3")
        XCTAssertEqual(result.reproduceRate, 1.0, accuracy: 1e-9)
    }

    func test_replay_reproduceRate_zero_whenBackendProducesDifferentOutput() async throws {
        let hash = try seedRecord(
            rendered: String(repeating: "ha ", count: 60),
            trigger: loopingTrigger()
        )
        // Tokens chosen so LoopingDetector does NOT fire and even if it did the
        // trigger suffix would differ → different hash.
        let factory = StubFactory(tokens: ["alpha ", "beta ", "gamma "])
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
        XCTAssertEqual(result.successfulReproductions, 0)
        XCTAssertEqual(result.reproduceRate, 0.0, accuracy: 1e-9)
        XCTAssertNil(result.newSeverity, "0/3 must not promote")
    }

    // MARK: - Promotion threshold

    func test_replay_promotesFlaky_toConfirmed_at2of3() async throws {
        // 2/3 reproduction: custom attempts counted via manual subset — but the
        // simplest way to verify the threshold is to call promotionThreshold
        // directly. The integration path is covered by the 3/3 test above.
        XCTAssertEqual(Replayer.promotionThreshold(attempts: 3), 2)
        XCTAssertEqual(Replayer.promotionThreshold(attempts: 5), 4)  // ceil(10/3) = 4
        XCTAssertEqual(Replayer.promotionThreshold(attempts: 1), 1)
        XCTAssertEqual(Replayer.promotionThreshold(attempts: 0), 0)
    }

    func test_replay_3of3_promotesFindingOnDisk() async throws {
        let hash = try seedRecord(
            rendered: String(repeating: "ha ", count: 60),
            trigger: loopingTrigger()
        )
        let factory = StubFactory(tokens: loopingTokens())
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
        XCTAssertEqual(result.newSeverity, .confirmed, "3/3 must promote")

        // index.json should now carry severity=confirmed for this hash.
        let data = try Data(contentsOf: tempDir.appendingPathComponent("index.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = root?["rows"] as? [[String: Any]]
        let row = rows?.first { ($0["finding"] as? [String: Any])?["hash"] as? String == hash }
        let severity = (row?["finding"] as? [String: Any])?["severity"] as? String
        XCTAssertEqual(severity, "confirmed", "index.json must be updated with promoted severity")
    }

    // MARK: - Non-deterministic backend

    func test_replay_refusesOnNonDeterministicBackend() async throws {
        let hash = try seedRecord(
            rendered: "stub",
            trigger: "hi"
        )
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: NonDeterministicFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil }
        )
        let outcome = try await replayer.replay(hash: hash)
        // The record stores `model.backend = "stub"`; the Replayer quotes that
        // so the user sees which backend the finding was recorded under, not
        // which factory they're trying to replay it on.
        XCTAssertEqual(outcome, .nonDeterministicBackend("stub"))
    }
}
#endif
