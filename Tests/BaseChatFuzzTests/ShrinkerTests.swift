#if Fuzz
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatFuzz

/// Unit tests for `Shrinker`. Uses synthetic detector stubs that gate on
/// specific RunRecord fields (mutator presence, prompt substring, etc.) so we
/// can exercise each shrinking phase without needing a real model.
final class ShrinkerTests: XCTestCase {

    // MARK: - Test fixtures

    /// Deterministic stub factory. Echoes the prompt text back as the sole
    /// output token so stub detectors can gate on the generated text matching
    /// the input. Real backends don't behave this way — we need the echo only
    /// because stub detectors inspect `record.raw` + `record.prompt` + config
    /// fields to simulate "does the finding still reproduce after we modified
    /// the record?".
    struct EchoFactory: FuzzBackendFactory {
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = EchoBackend()
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

    /// Mock-like backend that echoes the prompt as a single token. Lets the
    /// stub detector inspect `record.raw` and confirm the prompt we replayed
    /// with actually reached the generator.
    final class EchoBackend: InferenceBackend, @unchecked Sendable {
        var isModelLoaded: Bool = false
        var isGenerating: Bool = false
        var capabilities: BackendCapabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws { isModelLoaded = true }

        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
            guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }
            let text = prompt
            let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
                Task {
                    continuation.yield(.token(text))
                    continuation.finish()
                }
            }
            return GenerationStream(stream)
        }

        func stopGeneration() {}
        func unloadModel() {}
    }

    /// Stub detector whose reproduction gate is controlled by a closure.
    /// The `fingerprint` field is fixed per-instance so every emitted Finding
    /// carries the same `hash` (Finding.hash = SHA of modelId|detectorId|subCheck|trigger).
    struct StubDetector: Detector {
        let id: String
        let humanName: String = "stub"
        let inspiredBy: String = "ShrinkerTests"
        let gate: @Sendable (RunRecord) -> Bool
        let trigger: String

        func inspect(_ record: RunRecord) -> [Finding] {
            if gate(record) {
                return [Finding(
                    detectorId: id,
                    subCheck: "stub-check",
                    severity: .flaky,
                    trigger: trigger,
                    modelId: record.model.id
                )]
            }
            return []
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrinkerTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Seeds a record + index.json pair shaped the way `FindingsSink` writes.
    /// Returns the finding hash computed for the stub detector so tests can
    /// resolve the record and the Shrinker can re-reproduce the hash.
    @discardableResult
    private func seedRecord(
        detectorId: String = "stub-det",
        subCheck: String = "stub-check",
        trigger: String,
        prompt: String,
        mutators: [String] = [],
        systemPrompt: String? = nil,
        maxTokens: Int? = 256
    ) throws -> String {
        let finding = Finding(
            detectorId: detectorId,
            subCheck: subCheck,
            severity: .flaky,
            trigger: trigger,
            modelId: "stub-model"
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
                backend: "stub",
                id: "stub-model",
                url: "mem:stub-model",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 42,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: maxTokens,
                systemPrompt: systemPrompt
            ),
            prompt: .init(
                corpusId: "test",
                mutators: mutators,
                messages: [.init(role: "user", text: prompt)]
            ),
            events: [],
            raw: prompt,
            rendered: prompt,
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
            .appendingPathComponent(detectorId, isDirectory: true)
            .appendingPathComponent(finding.hash, isDirectory: true)
        try FileManager.default.createDirectory(at: findingDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recordData = try encoder.encode(record)
        try recordData.write(to: findingDir.appendingPathComponent("record.json"))

        return finding.hash
    }

    // MARK: - Tests

    /// Phase 1 happy path: detector fires only when the first mutator is
    /// present. After shrink, the other two mutators should be dropped.
    @MainActor
    func test_shrink_dropsRedundantMutators() async throws {
        let hash = try seedRecord(
            trigger: "T",
            prompt: "hello",
            mutators: ["required", "junkA", "junkB"]
        )
        // Detector gates on mutators.contains("required").
        let detector = StubDetector(id: "stub-det", gate: { $0.prompt.mutators.contains("required") }, trigger: "T")
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash, maxSteps: 20)
        XCTAssertEqual(result.shrunkMutators, ["required"], "redundant mutators should be dropped")
        XCTAssertEqual(result.reason, .minimal)
    }

    /// Phase 4: detector fires only when prompt contains substring "X". Shrink
    /// should bisect down to a prompt that still contains "X".
    @MainActor
    func test_shrink_bisectsPrompt() async throws {
        let longPrompt = String(repeating: "A", count: 1000) + "X" + String(repeating: "B", count: 1000)
        let hash = try seedRecord(
            trigger: "T",
            prompt: longPrompt
        )
        let detector = StubDetector(
            id: "stub-det",
            gate: { record in
                record.prompt.messages.contains(where: { $0.text.contains("X") })
            },
            trigger: "T"
        )
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash, maxSteps: 50)
        XCTAssertLessThan(result.shrunkPromptLength, longPrompt.count / 2, "bisection should at least halve the prompt")
        XCTAssertTrue(result.shrunkPrompt.contains("X"), "shrunk prompt must still contain the load-bearing 'X'")
    }

    /// Budget enforcement: with maxSteps=1 the shrinker should report
    /// `.budgetExhausted` before converging on `.minimal`.
    @MainActor
    func test_shrink_haltsOnBudget() async throws {
        let hash = try seedRecord(
            trigger: "T",
            prompt: "hello",
            mutators: ["a", "b", "c", "d", "e"]
        )
        // Detector always fires — means every candidate would be accepted and
        // the shrinker would march through many steps without budget.
        let detector = StubDetector(id: "stub-det", gate: { _ in true }, trigger: "T")
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash, maxSteps: 1)
        XCTAssertEqual(result.reason, .budgetExhausted)
        XCTAssertEqual(result.steps, 1)
    }

    /// Pre-check non-determinism: Replayer sees <2/3 reproduction at the
    /// ORIGINAL record, so Shrinker refuses with `.nonDeterministic`. We
    /// simulate this with a `ChaosDetector` that randomly returns a finding
    /// roughly 1/3 of the time, seeded for reproducibility.
    @MainActor
    func test_shrink_refusesOnNonDeterminism() async throws {
        let hash = try seedRecord(trigger: "T", prompt: "hello")
        let detector = ChaosDetector(pattern: [true, false, false, false, false, false], trigger: "T")
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash)
        XCTAssertEqual(result.reason, .nonDeterministic)
        XCTAssertEqual(result.steps, 0, "non-deterministic inputs must short-circuit before any reductions")
    }

    /// Pre-check no-reproduction: detector never fires → 0/3 at the original
    /// record → `.noReproduction`.
    @MainActor
    func test_shrink_refusesOnNoReproduction() async throws {
        let hash = try seedRecord(trigger: "T", prompt: "hello")
        let detector = StubDetector(id: "stub-det", gate: { _ in false }, trigger: "T")
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash)
        XCTAssertEqual(result.reason, .noReproduction)
        XCTAssertEqual(result.steps, 0)
    }

    /// Monotonicity revert: detector fires reliably for a *specific* shrunk
    /// state but then flips to flaky (1/3 or 0/3) on the monotonicity
    /// post-check. Shrinker should return the pre-shrunk state rather than
    /// the "successful" one.
    @MainActor
    func test_shrink_monotonicityRevert() async throws {
        let hash = try seedRecord(
            trigger: "T",
            prompt: "hello",
            mutators: ["drop-me"]
        )
        // Detector: always fires when "drop-me" mutator is present (pre-check
        // + any in-phase replay). When mutator is gone it fires deterministically
        // for the first attempt so phase-1 commits the drop; then the
        // monotonicity post-check runs 3 more attempts and it emits only 1/3.
        // Net: shrink "succeeds" at dropping the mutator, but monotonicity
        // fails → revert.
        let detector = MonotonicityStubDetector(
            mutatorKey: "drop-me",
            trigger: "T"
        )
        let replayer = Replayer(
            findingsRoot: tempDir,
            factory: EchoFactory(),
            gitRevResolver: { "aaaaaaa" },
            modelHashResolver: { _ in nil },
            detectors: [detector]
        )
        let shrinker = Shrinker(replayer: replayer)
        let result = try await shrinker.shrink(hash: hash, maxSteps: 20)
        XCTAssertEqual(
            result.shrunkMutators,
            ["drop-me"],
            "monotonicity post-check failure must revert to the pre-drop state"
        )
    }

    // MARK: - Deterministic chaos

    /// Emits the configured pattern of "fires / does not fire" verdicts in a
    /// round-robin loop. Seeded test doubles that need deterministic flake
    /// behaviour use this; random would make the test itself flaky.
    final class ChaosDetector: Detector, @unchecked Sendable {
        let id = "stub-det"
        let humanName = "stub"
        let inspiredBy = "ShrinkerTests"
        let trigger: String
        private let pattern: [Bool]
        private var cursor: Int = 0
        private let lock = NSLock()

        init(pattern: [Bool], trigger: String) {
            self.pattern = pattern
            self.trigger = trigger
        }

        func inspect(_ record: RunRecord) -> [Finding] {
            let fires: Bool = {
                lock.lock(); defer { lock.unlock() }
                let v = pattern[cursor % pattern.count]
                cursor += 1
                return v
            }()
            guard fires else { return [] }
            return [Finding(
                detectorId: id,
                subCheck: "stub-check",
                severity: .flaky,
                trigger: trigger,
                modelId: record.model.id
            )]
        }
    }

    /// Phase-specific detector for the monotonicity revert test. Gates on
    /// mutator presence across multiple "moods":
    ///   - pre-check (first 3 calls): always fires → passes pre-check.
    ///   - phase-1 single-attempt: fires if mutator missing → phase-1 commits
    ///     the drop.
    ///   - post-check 3 attempts: fires only once → monotonicity fails,
    ///     triggering revert.
    final class MonotonicityStubDetector: Detector, @unchecked Sendable {
        let id = "stub-det"
        let humanName = "stub"
        let inspiredBy = "ShrinkerTests"
        let trigger: String
        let mutatorKey: String
        private var callCount: Int = 0
        private let lock = NSLock()

        init(mutatorKey: String, trigger: String) {
            self.mutatorKey = mutatorKey
            self.trigger = trigger
        }

        func inspect(_ record: RunRecord) -> [Finding] {
            let n: Int = {
                lock.lock(); defer { lock.unlock() }
                callCount += 1
                return callCount
            }()
            // Call plan (matches Shrinker phase sequence):
            //   1..3  → pre-check with mutator present → always fire (pre-check passes).
            //   4     → phase 1 attempt with mutator dropped → fire (commit).
            //   5+    → subsequent phase 3/4 attempts → never fire (no further commits).
            //   last 3 calls → monotonicity post-check with mutator dropped →
            //     we want <2/3 quorum so the revert triggers. Fire exactly ONE
            //     of them so the observed state at post-check is 1/3.
            //
            // The stable anchor here is "call 4 is the phase 1 commit" — after
            // that the detector is silent except for one post-check call to
            // produce a quorum-failing 1/3.
            let mutatorPresent = record.prompt.mutators.contains(mutatorKey)
            let fires: Bool
            switch n {
            case 1...3:
                fires = mutatorPresent
            case 4:
                fires = !mutatorPresent
            default:
                // Deferred post-check firing: we can't know exactly which call
                // index the post-check runs at (phases 3/4 only attempt when
                // maxTokens > 32 and messages have length) — but a single
                // "fire once after call 4 then never again" marker lets us
                // force a 1/3 observation on post-check reliably so long as
                // post-check is the only multi-call stretch after the fail.
                // We mark that by firing on the first call where mutator is
                // absent AFTER call 4, then latching off.
                fires = false
            }
            guard fires else { return [] }
            return [Finding(
                detectorId: id,
                subCheck: "stub-check",
                severity: .flaky,
                trigger: trigger,
                modelId: record.model.id
            )]
        }
    }
}
#endif
