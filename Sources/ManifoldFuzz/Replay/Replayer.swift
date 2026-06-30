import Foundation
import ManifoldInference

/// Replays a previously-recorded fuzz finding to separate flakes from confirmed
/// bugs. Resolves a finding hash to its stored `record.json`, refuses on git/model
/// drift (top-3 DevEx abandonment risk — "it worked yesterday" non-repro), re-runs
/// the exact recorded prompt + sampler config N times, and promotes the finding's
/// severity from `.flaky` to `.confirmed` when the same detector hash fires in a
/// quorum of attempts.
///
/// Lives parallel to `FuzzRunner` rather than inside it: replay is a distinct
/// mode of operation (no campaign loop, no corpus sampling, full input determinism)
/// and bolting it onto the runner would conflate two responsibilities.
public struct Replayer: Sendable {

    public struct Result: Sendable, Equatable {
        /// Fraction of attempts that re-produced the original finding hash.
        public let reproduceRate: Double
        /// Count of attempts that hit the same finding hash.
        public let successfulReproductions: Int
        public let attempts: Int
        /// Set to `.confirmed` when the result met the promotion threshold.
        /// `nil` means the severity stays as it was.
        public let newSeverity: Severity?
        /// Populated when `--force` was used despite drift.
        public let drift: DriftReport?
    }

    public struct DriftReport: Sendable, Equatable {
        public let recordedGitRev: String
        public let currentGitRev: String
        public let recordedModelHash: String?
        public let currentModelHash: String?

        public var gitDrifted: Bool {
            recordedGitRev != currentGitRev
        }

        /// True only when both sides are non-nil and differ. A nil on either side
        /// is treated as "unknown" and does NOT count as drift.
        public var modelHashDrifted: Bool {
            guard let a = recordedModelHash, let b = currentModelHash else { return false }
            return a != b
        }

        public var any: Bool { gitDrifted || modelHashDrifted }
    }

    public enum Outcome: Sendable, Equatable {
        case reproduced(Result)
        case driftRefused(DriftReport)
        case recordNotFound
        case schemaUnsupported(Int)
        case nonDeterministicBackend(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case decodeFailed(String)
    }

    private let findingsRoot: URL
    private let factory: any FuzzBackendFactory
    private let gitRevResolver: @Sendable () -> String
    private let modelHashResolver: @Sendable (URL) -> String?
    private let clock: @Sendable () -> Date
    private let detectors: [any Detector]

    /// Designated initialiser. The resolver closures let tests substitute
    /// deterministic values for the shelled-out git rev and the file-hash scan.
    /// `detectors` defaults to `DetectorRegistry.all`; tests override to inject
    /// stub detectors that gate on specific RunRecord fields (e.g. mutator id
    /// presence) — required for Shrinker unit tests.
    public init(
        findingsRoot: URL,
        factory: any FuzzBackendFactory,
        gitRevResolver: (@Sendable () -> String)? = nil,
        modelHashResolver: (@Sendable (URL) -> String?)? = nil,
        clock: (@Sendable () -> Date)? = nil,
        detectors: [any Detector]? = nil
    ) {
        self.findingsRoot = findingsRoot
        self.factory = factory
        self.gitRevResolver = gitRevResolver ?? { Replayer.resolveCurrentGitRev() }
        self.modelHashResolver = modelHashResolver ?? { HarnessMetadata.fileSHA256($0) }
        self.clock = clock ?? { Date() }
        self.detectors = detectors ?? DetectorRegistry.all
    }

    public func replay(
        hash: String,
        attempts: Int = 3,
        force: Bool = false
    ) async throws -> Outcome {
        // 1. Resolve hash -> record.json.
        guard let recordURL = resolveRecordURL(hash: hash) else {
            return .recordNotFound
        }

        let decoder = JSONDecoder()
        let data: Data
        do {
            data = try Data(contentsOf: recordURL)
        } catch {
            throw Failure.decodeFailed("read failed at \(recordURL.path): \(error)")
        }
        let record: RunRecord
        do {
            record = try decoder.decode(RunRecord.self, from: data)
        } catch {
            throw Failure.decodeFailed("JSON decode failed: \(error)")
        }

        // 2. Schema check — future versions can't be trusted.
        do {
            try RunRecord.validate(schemaVersion: record.schemaVersion)
        } catch RunRecord.SchemaError.unsupportedFutureSchema(let v) {
            return .schemaUnsupported(v)
        }

        // 3. Non-deterministic backend check — cloud backends refuse outright.
        if !factory.supportsDeterministicReplay {
            return .nonDeterministicBackend(record.model.backend)
        }

        // 4. Drift check.
        let drift = buildDriftReport(record: record)
        if drift.any && !force {
            return .driftRefused(drift)
        }
        if drift.any && force {
            Log.inference.warning(
                "Replayer: proceeding with --force despite drift (git \(drift.recordedGitRev, privacy: .public) -> \(drift.currentGitRev, privacy: .public), model \(drift.recordedModelHash ?? "nil", privacy: .public) -> \(drift.currentModelHash ?? "nil", privacy: .public))"
            )
        }

        // 5. Run the recorded prompt attempts times.
        let handle = try await factory.makeHandle()

        var successes = 0
        for _ in 0..<attempts {
            let replayRecord = await runOnce(handle: handle, record: record)
            if findingHashReproduced(originalHash: hash, record: replayRecord) {
                successes += 1
            }
        }

        let rate = attempts > 0 ? Double(successes) / Double(attempts) : 0
        let threshold = Self.promotionThreshold(attempts: attempts)
        let promoted = successes >= threshold

        // 6. Persist severity promotion back to disk — preserve schemaVersion.
        if promoted {
            do {
                try promoteStoredFinding(recordURL: recordURL, hash: hash)
            } catch {
                // Promotion-persistence failure is recoverable: the in-memory
                // Result still reports `.confirmed`, the caller has its answer,
                // and the on-disk record retains its original severity. Log so
                // the next replay of the same hash will re-attempt promotion.
                Log.inference.warning(
                    "Replayer: failed to persist severity promotion for \(hash, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        let result = Result(
            reproduceRate: rate,
            successfulReproductions: successes,
            attempts: attempts,
            newSeverity: promoted ? .confirmed : nil,
            drift: force && drift.any ? drift : nil
        )
        return .reproduced(result)
    }

    /// Runs `attempts` replays against a caller-supplied record and returns the
    /// count of runs whose output reproduced `originalHash`. Skips drift /
    /// schema / resolution entirely — the caller owns the record and is
    /// responsible for those checks. `Shrinker` uses this to evaluate mutated
    /// candidate records (shorter prompts, dropped mutators, etc.) without
    /// round-tripping through the findings directory.
    @MainActor
    public func replay(
        record: RunRecord,
        originalHash: String,
        attempts: Int
    ) async throws -> Int {
        let handle = try await factory.makeHandle()
        var successes = 0
        for _ in 0..<attempts {
            let replayRecord = await runOnce(handle: handle, record: record)
            if findingHashReproduced(originalHash: originalHash, record: replayRecord) {
                successes += 1
            }
        }
        return successes
    }

    /// Loads + decodes the record for a hash. Public so `Shrinker` can materialise
    /// the record once and then mutate candidates from it in-memory.
    public func loadRecord(hash: String) throws -> RunRecord? {
        guard let url = resolveRecordURL(hash: hash) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.decodeFailed("read failed at \(url.path): \(error)")
        }
        do {
            return try JSONDecoder().decode(RunRecord.self, from: data)
        } catch {
            throw Failure.decodeFailed("JSON decode failed: \(error)")
        }
    }

    /// URL under which shrink artefacts for `hash` should be written. Exposed so
    /// `Shrinker` can persist `shrunk.json` alongside the seed `record.json`.
    public func findingDirectory(forHash hash: String) -> URL? {
        guard let recordURL = resolveRecordURL(hash: hash) else { return nil }
        return recordURL.deletingLastPathComponent()
    }

    /// Promotion threshold: `ceil(2/3 * attempts)`, floored at 1 so a single-shot
    /// replay can still confirm. The spec calls out 2/3 specifically; the ceil
    /// generalises cleanly when the caller passes a different attempt count.
    public static func promotionThreshold(attempts: Int) -> Int {
        guard attempts > 0 else { return 0 }
        let num = 2 * attempts
        let den = 3
        return max(1, (num + den - 1) / den)
    }

    // MARK: - Resolution

    /// Scans `<findingsRoot>/findings/*/<hash>/record.json`. The detector id is
    /// not known ahead of time, so we glob across every detector folder.
    public func resolveRecordURL(hash: String) -> URL? {
        let findingsDir = findingsRoot.appendingPathComponent("findings", isDirectory: true)
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: findingsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Absence is the expected "no findings yet" case — log at debug so
            // users don't see noise. Non-ENOENT failures (permissions, etc.)
            // surface via the same log line but still resolve to `nil` → caller
            // gets `.recordNotFound` and a clean error message.
            Log.inference.debug(
                "Replayer.resolveRecordURL: cannot enumerate \(findingsDir.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
        for detectorDir in entries {
            let candidate = detectorDir
                .appendingPathComponent(hash, isDirectory: true)
                .appendingPathComponent("record.json")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Drift

    private func buildDriftReport(record: RunRecord) -> DriftReport {
        let currentRev = gitRevResolver()
        let recordedRev = record.harness.packageGitRev

        // Model hash: if the record doesn't have one (typical today — MLX/Llama
        // not wired yet), we skip the compare rather than refuse. We'll still
        // capture it on the current side if the model URL points at something we
        // can hash; that at least lights up on the "was nil yesterday, known
        // today" direction once hashes are populated upstream.
        let recordedHash = record.model.fileSHA256
        let modelURL = URL(string: record.model.url)
        let currentHash: String? = {
            guard let url = modelURL, url.isFileURL else { return nil }
            return modelHashResolver(url)
        }()

        return DriftReport(
            recordedGitRev: recordedRev,
            currentGitRev: currentRev,
            recordedModelHash: recordedHash,
            currentModelHash: currentHash
        )
    }

    /// Shell out to `git rev-parse --short HEAD` — same invocation shape
    /// `HarnessMetadata` uses on capture. Returns "unknown" on failure so
    /// comparison still works (recorded rev != "unknown" → drift).
    static func resolveCurrentGitRev() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--short", "HEAD"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? "unknown"
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }

    // MARK: - Execution

    /// Runs a single attempt using the prompt + sampler config from the record.
    /// Does NOT touch `FuzzRunner`'s sampling loop — replay is deterministic
    /// input, not random exploration. The `record.config.seed` is passed into the
    /// fresh `FuzzConfig` purely so the `ConfigSnapshot` emitted by this attempt
    /// carries the recorded seed; sampling is bypassed. The seed-plumbing sabotage
    /// test asserts this field is NOT silently replaced with a fresh seed.
    private func runOnce(
        handle: FuzzRunner.BackendHandle,
        record: RunRecord
    ) async -> RunRecord {
        let memBefore = AppMemoryUsage.currentBytes()
        let start = ContinuousClock.now

        let prompt = record.prompt.messages.map(\.text).joined(separator: "\n")
        // Re-drive with the RECORDED sampler config — seed, topK, and
        // repeatPenalty included. Threading the recorded seed is what makes the
        // `supportsDeterministicReplay` gate honest: without it, replay sampled
        // against the backend's default RNG and could not reproduce a
        // seed-dependent finding.
        var cfg = GenerationConfig(
            temperature: record.config.temperature,
            topP: record.config.topP,
            repeatPenalty: record.config.repeatPenalty,
            maxOutputTokens: record.config.maxTokens
        )
        cfg.seed = record.config.seed
        cfg.topK = record.config.topK

        var capture: EventRecorder.Capture
        do {
            let stream = try handle.backend.generate(
                prompt: prompt,
                systemPrompt: record.config.systemPrompt,
                config: cfg
            )
            capture = await EventRecorder().consume(stream, maxOutputTokens: record.config.maxTokens)
        } catch {
            capture = EventRecorder.Capture(
                events: [],
                raw: "",
                thinkingRaw: "",
                thinkingParts: [],
                thinkingCompleteCount: 0,
                phase: "failed",
                error: String(describing: error),
                firstTokenMs: nil,
                totalMs: start.duration(to: ContinuousClock.now).milliseconds,
                peakBytes: memBefore,
                promptTokens: nil,
                completionTokens: nil,
                stopReason: "error"
            )
        }

        let memAfter = AppMemoryUsage.currentBytes()
        let tps: Double? = {
            guard let p = capture.promptTokens,
                  let c = capture.completionTokens,
                  let firstToken = capture.firstTokenMs,
                  capture.totalMs > firstToken else { return nil }
            _ = p
            return Double(c) / ((capture.totalMs - firstToken) / 1000.0)
        }()

        return RunRecord(
            runId: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: clock()),
            // Harness/model snapshots track the REPLAY's environment; the drift
            // check already ran against the ORIGINAL record above. This makes
            // replay runs introspectable ("what rev/hash did I reproduce under?").
            harness: RunRecord.HarnessSnapshot(
                fuzzVersion: HarnessMetadata.fuzzVersion,
                packageGitRev: gitRevResolver(),
                packageGitDirty: record.harness.packageGitDirty,
                swiftVersion: record.harness.swiftVersion,
                osBuild: record.harness.osBuild,
                thermalState: HarnessMetadata.currentThermalState()
            ),
            model: RunRecord.ModelSnapshot(
                backend: handle.backendName,
                id: handle.modelId,
                url: handle.modelURL.absoluteString,
                fileSHA256: record.model.fileSHA256,
                tokenizerHash: record.model.tokenizerHash
            ),
            config: RunRecord.ConfigSnapshot(
                // This is the seed-plumbing correctness surface: the recorded
                // seed must round-trip into the replay's ConfigSnapshot.
                // Sabotage by replacing with a fresh value and the determinism
                // test should fail.
                seed: record.config.seed,
                temperature: record.config.temperature,
                topP: record.config.topP,
                maxTokens: record.config.maxTokens,
                systemPrompt: record.config.systemPrompt,
                topK: record.config.topK,
                repeatPenalty: record.config.repeatPenalty
            ),
            prompt: RunRecord.PromptSnapshot(
                corpusId: record.prompt.corpusId,
                mutators: record.prompt.mutators,
                messages: record.prompt.messages
            ),
            events: capture.events,
            raw: capture.raw,
            rendered: MarkdownRendering.renderToVisibleString(capture.raw),
            thinkingRaw: capture.thinkingRaw,
            thinkingParts: capture.thinkingParts,
            thinkingCompleteCount: capture.thinkingCompleteCount,
            templateMarkers: handle.templateMarkers,
            memory: RunRecord.MemorySnapshot(
                beforeBytes: memBefore,
                peakBytes: capture.peakBytes,
                afterBytes: memAfter
            ),
            timing: RunRecord.TimingSnapshot(
                firstTokenMs: capture.firstTokenMs,
                totalMs: capture.totalMs,
                tokensPerSec: tps
            ),
            phase: capture.phase,
            error: capture.error,
            stopReason: capture.stopReason
        )
    }

    /// Re-runs every detector against the new record and returns true if any
    /// emitted Finding shares the hash we were trying to reproduce.
    private func findingHashReproduced(originalHash: String, record: RunRecord) -> Bool {
        for detector in detectors {
            for finding in detector.inspect(record) {
                if finding.hash == originalHash { return true }
            }
        }
        return false
    }

    // MARK: - Promotion persistence

    /// Rewrites `summary.txt` + updates the severity line in `index.json` so
    /// `INDEX.md` regenerations pick up the confirmed state. We intentionally do
    /// NOT rewrite `record.json` — the original record is the minimal repro and
    /// overwriting it destroys provenance. Severity lives on the Finding, which
    /// lives in index.json, so that's where the mutation belongs.
    private func promoteStoredFinding(recordURL: URL, hash: String) throws {
        let findingDir = recordURL.deletingLastPathComponent()

        let indexURL = findingsRoot.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        let data = try Data(contentsOf: indexURL)

        // Decode the envelope into a mutable JSON object tree so we can flip
        // severity without depending on FindingsSink's private IndexRow/IndexFile
        // types. Staying loose here keeps the Replayer decoupled from sink shape.
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var rows = root["rows"] as? [[String: Any]] else {
            return
        }
        for i in rows.indices {
            guard var finding = rows[i]["finding"] as? [String: Any],
                  let rowHash = finding["hash"] as? String,
                  rowHash == hash else { continue }
            finding["severity"] = Severity.confirmed.rawValue
            rows[i]["finding"] = finding
        }
        root["rows"] = rows
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: indexURL)

        // Best-effort summary.txt refresh so `open tmp/fuzz/findings/.../summary.txt`
        // reflects the promotion. A missing/unreadable/unwritable summary is
        // not fatal — index.json is the source of truth for INDEX.md
        // regeneration; summary.txt is a human-readable mirror.
        let summaryURL = findingDir.appendingPathComponent("summary.txt")
        do {
            let existing = try String(contentsOf: summaryURL, encoding: .utf8)
            let promoted = existing.replacingOccurrences(of: "flaky |", with: "confirmed |")
            do {
                try promoted.write(to: summaryURL, atomically: true, encoding: .utf8)
            } catch {
                Log.inference.warning(
                    "Replayer: failed to rewrite summary.txt at \(summaryURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        } catch {
            Log.inference.debug(
                "Replayer: summary.txt not readable at \(summaryURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let comps = self.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}
