import Foundation
import ManifoldInference

/// Drives a fuzzing campaign: samples (corpus entry, config), drives `runSingle`
/// for each iteration, runs detectors over the resulting `RunRecord`, and writes
/// findings via `FindingsSink`. Backend instantiation is delegated to a
/// `FuzzBackendFactory` so the engine stays free of MLX/Llama/Ollama
/// dependencies.
public actor FuzzRunner {

    public struct BackendHandle: Sendable {
        public let backend: any InferenceBackend
        public let modelId: String
        public let modelURL: URL
        public let backendName: String
        public let templateMarkers: RunRecord.MarkerSnapshot?
        /// Per-model memory budget in bytes, when the factory can supply one
        /// (e.g. a companion MLX/Llama factory reporting the loaded weights'
        /// file size). `nil` for factories with no real per-model ceiling to
        /// report (mock, chaos, Ollama, cloud) — `MemoryGrowthDetector`'s
        /// budget-exceeded branch stays a no-op for those, honestly, rather
        /// than fabricating a number.
        public let memoryBudgetBytes: UInt64?

        public init(
            backend: any InferenceBackend,
            modelId: String,
            modelURL: URL,
            backendName: String,
            templateMarkers: RunRecord.MarkerSnapshot?,
            memoryBudgetBytes: UInt64? = nil
        ) {
            self.backend = backend
            self.modelId = modelId
            self.modelURL = modelURL
            self.backendName = backendName
            self.templateMarkers = templateMarkers
            self.memoryBudgetBytes = memoryBudgetBytes
        }
    }

    private let config: FuzzConfig
    private let factory: any FuzzBackendFactory
    private let sink: FindingsSink
    private let corpus: [CorpusEntry]
    private var rng: SeededRNG
    /// Cached harness snapshot. Git/swift fields are immutable for the process
    /// lifetime; only `thermalState` is refreshed per iteration. Avoids
    /// reshelling git+swift on every record (was 3 subprocess spawns each).
    private let harnessBaseline: RunRecord.HarnessSnapshot

    public init(config: FuzzConfig, factory: any FuzzBackendFactory) {
        self.config = config
        self.factory = factory
        self.sink = FindingsSink(outputDir: config.outputDir)
        self.corpus = Corpus.load(subset: config.corpusSubset)
        self.rng = SeededRNG(seed: config.seed)
        self.harnessBaseline = HarnessMetadata.snapshot(repoRoot: nil)
    }

    /// Reuses the cached baseline and refreshes only the drifting field.
    private func currentHarnessSnapshot() -> RunRecord.HarnessSnapshot {
        var snap = harnessBaseline
        snap.thermalState = HarnessMetadata.currentThermalState()
        return snap
    }

    public func run(reporter: TerminalReporter) async -> FuzzReport {
        guard !corpus.isEmpty else {
            await reporter.error("No corpus entries available — Resources/corpus/seeds.json missing?")
            return FuzzReport(totalRuns: 0, findings: [], dedupedCount: 0, perDetectorFlagRate: [:], realCompletions: 0)
        }

        // Prime the factory once before the loop. The first handle double-duties
        // as the preflight target (keeps the banner line stable) and as the
        // iteration-1 handle, which matches the pre-#501 single-model cost
        // profile for campaigns that never rotate.
        let primeHandle: BackendHandle
        do {
            primeHandle = try await factory.makeHandle()
        } catch {
            await reporter.error("Backend factory failed: \(error)")
            return FuzzReport(totalRuns: 0, findings: [], dedupedCount: 0, perDetectorFlagRate: [:], realCompletions: 0)
        }

        let detectors = DetectorRegistry.resolve(config.detectorFilter)
        await reporter.preflight(backend: primeHandle.backendName, model: primeHandle.modelId, detectors: detectors.map(\.id))

        let deadline: ContinuousClock.Instant?
        if let minutes = config.minutes {
            deadline = ContinuousClock.now.advanced(by: .seconds(minutes * 60))
        } else {
            deadline = nil
        }
        let iterCap = config.iterations ?? Int.max
        var iter = 0
        var totalFindings = 0
        var perDetector: [String: Int] = [:]
        // Every completed iteration whose `RunRecord.phase == "done"` — feeds
        // `FuzzReport.isInert` (ManifoldKit#2344's floor-rate guard).
        var realCompletions = 0
        // Reuse `primeHandle` on the first iteration so single-model campaigns
        // pay the factory once; rotating factories hand back a new model from
        // iteration 2 onward. This is the minimum change needed to let option
        // (b) from #501 actually rotate — `RotatingFuzzFactory` advances its
        // index per `makeHandle()` call, which now happens per iteration.
        var pendingHandle: BackendHandle? = primeHandle

        while iter < iterCap {
            if let deadline, ContinuousClock.now >= deadline { break }
            iter += 1

            let handle: BackendHandle
            if let pending = pendingHandle {
                handle = pending
                pendingHandle = nil
            } else {
                do {
                    handle = try await factory.makeHandle()
                } catch {
                    await reporter.error("Backend factory failed mid-run: \(error)")
                    break
                }
            }

            let baseEntry = corpus.randomElement(using: &rng)!
            let (entry, appliedMutators) = MutatorChain.allRandom(baseEntry, rng: &rng)
            let temp = [Float(0.0), 0.2, 0.7, 1.0, 1.5].randomElement(using: &rng)!
            let topP = [Float(0.5), 0.9, 1.0].randomElement(using: &rng)!
            let maxTokens = [64, 256, 512].randomElement(using: &rng)!

            await reporter.iterationStart(iter: iter, model: handle.modelId, temp: temp, totalFindings: totalFindings)

            let harnessSnap = currentHarnessSnapshot()
            let record = await runSingle(
                handle: handle,
                entry: entry,
                appliedMutators: appliedMutators,
                temperature: temp,
                topP: topP,
                maxTokens: maxTokens,
                harness: harnessSnap
            )
            await reporter.iterationEnd()

            if record.phase == "done" { realCompletions += 1 }

            var iterationFindings: [Finding] = []
            for detector in detectors {
                let f = detector.inspect(record)
                iterationFindings.append(contentsOf: f)
            }

            if iterationFindings.isEmpty {
                await sink.noteEmptyRun()
            } else {
                totalFindings += iterationFindings.count
                for f in iterationFindings {
                    perDetector[f.detectorId, default: 0] += 1
                    await reporter.finding(f)
                }
                await sink.recordRun(record, findings: iterationFindings)
            }
        }

        await factory.teardown()

        let snapshot = await sink.snapshot()
        let perDetectorRate = perDetector.mapValues { Double($0) / Double(max(iter, 1)) }
        let report = FuzzReport(
            totalRuns: iter,
            findings: snapshot.findings,
            dedupedCount: snapshot.findings.count,
            perDetectorFlagRate: perDetectorRate,
            realCompletions: realCompletions
        )
        if report.isInert {
            await reporter.error(
                "campaign ran \(iter) iteration(s) but NOT ONE reached a real completion "
                + "(RunRecord.phase == \"done\") — every turn failed, timed out, or never "
                + "generated. A clean \"findings=0\" report from this run is not evidence of "
                + "stability; it is evidence the rig never drove the backend. See ManifoldKit#2344."
            )
        }
        await reporter.finalSummary(report: report)
        return report
    }

    private func runSingle(
        handle: BackendHandle,
        entry: CorpusEntry,
        appliedMutators: [String],
        temperature: Float,
        topP: Float,
        maxTokens: Int,
        harness: RunRecord.HarnessSnapshot
    ) async -> RunRecord {
        let memBefore = AppMemoryUsage.currentBytes()
        let start = ContinuousClock.now

        let prompt = entry.turns.map(\.text).joined(separator: "\n")
        // Populates `ContextExhaustionSilentDetector`'s false-trigger suppression
        // guard, which was permanently dead without a live `contextLimit` /
        // `estimatedPromptTokens` pair (#39 in the 2026-07 inert-code audit).
        // The character-based estimate is the same heuristic
        // `PromptAssembler`/`ContextWindowManager` use elsewhere in the absence
        // of a real tokenizer — advisory, not exact.
        let contextLimit = handle.backend.capabilities.contextWindowSize
        let estimatedPromptTokens = ContextWindowManager.estimateTokenCount(entry.system ?? "")
            + ContextWindowManager.estimateTokenCount(prompt)
        let toolDefs: [ToolDefinition] = config.tools ? SyntheticToolset.definitions : []
        // `.auto` keeps the model honest — `.required` would mask the
        // toolchoice-violation sub-check during the day-one campaign. When the
        // detector matures we can sample across choice variants per iteration.
        let toolChoice: ToolChoice = .auto
        var cfg = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: 1.1,
            maxOutputTokens: maxTokens
        )
        cfg.tools = toolDefs
        cfg.toolChoice = toolChoice

        var capture: EventRecorder.Capture
        do {
            let stream = try handle.backend.generate(
                prompt: prompt,
                systemPrompt: entry.system,
                config: cfg
            )
            if handle.backendName == "openai" {
                // The cloud path already has its own protection —
                // `OpenAIFuzzFactory` wires `requestIdleTimeout` at the HTTP
                // transport layer, which resets on every byte received. A
                // second, wall-clock `GenerationTimeout` wrap here would
                // additionally hard-cut a slow-but-continuously-streaming
                // completion that the idle timeout correctly lets finish —
                // stacking a coarser cap on top of a finer one changes
                // behavior for the healthy case, not just the hung one. Only
                // backends with NO other protection (every non-cloud backend
                // in this harness) get the wall-clock cap below.
                capture = await EventRecorder().consume(stream, maxOutputTokens: maxTokens)
            } else {
                let requestTimeout = config.requestTimeout
                capture = await GenerationTimeout.run(
                    .seconds(requestTimeout),
                    operation: { await EventRecorder().consume(stream, maxOutputTokens: maxTokens) },
                    onTimeout: {
                        // Cancelling the operation task alone does not stop
                        // the backend's in-flight generation — the fuzz
                        // stream isn't guaranteed to observe
                        // `Task.isCancelled`. `stopGeneration()` is the
                        // contract-guaranteed way to actually terminate it
                        // (see `InferenceBackend.stopGeneration()`'s doc
                        // comment) and leave the backend ready for reuse.
                        handle.backend.stopGeneration()
                        return EventRecorder.Capture(
                            events: [],
                            raw: "",
                            thinkingRaw: "",
                            thinkingParts: [],
                            thinkingCompleteCount: 0,
                            phase: "timeout",
                            error: "generation exceeded requestTimeout (\(requestTimeout)s)",
                            firstTokenMs: nil,
                            totalMs: start.duration(to: ContinuousClock.now).milliseconds,
                            peakBytes: memBefore,
                            promptTokens: nil,
                            completionTokens: nil,
                            stopReason: "timeout"
                        )
                    }
                )
            }
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
            guard let p = capture.promptTokens, let c = capture.completionTokens, let firstToken = capture.firstTokenMs, capture.totalMs > firstToken else {
                return nil
            }
            _ = p
            return Double(c) / ((capture.totalMs - firstToken) / 1000.0)
        }()

        return RunRecord(
            runId: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            harness: harness,
            model: RunRecord.ModelSnapshot(
                backend: handle.backendName,
                id: handle.modelId,
                url: handle.modelURL.absoluteString,
                fileSHA256: nil,
                tokenizerHash: nil,
                memoryBudgetBytes: handle.memoryBudgetBytes
            ),
            config: RunRecord.ConfigSnapshot(
                seed: config.seed,
                temperature: temperature,
                topP: topP,
                maxTokens: maxTokens,
                systemPrompt: entry.system,
                toolChoice: toolDefs.isEmpty ? nil : encodeToolChoice(toolChoice),
                contextLimit: contextLimit
            ),
            prompt: RunRecord.PromptSnapshot(
                corpusId: entry.id,
                mutators: appliedMutators,
                messages: entry.turns.map { .init(role: $0.role, text: $0.text) },
                estimatedPromptTokens: estimatedPromptTokens
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
            stopReason: capture.stopReason,
            toolCalls: capture.toolCalls,
            toolResults: capture.toolResults,
            toolDefinitions: toolDefs,
            truncated: capture.truncated
        )
    }
}

public struct FuzzReport: Sendable {
    public let totalRuns: Int
    public let findings: [Finding]
    public let dedupedCount: Int
    public let perDetectorFlagRate: [String: Double]
    /// Count of turns across the whole campaign whose `RunRecord.phase == "done"`
    /// — i.e. a generation that actually ran to completion against the backend,
    /// as opposed to one that failed, timed out, or (session-scripts mode) never
    /// produced a record at all. See ``isInert``.
    public let realCompletions: Int

    public init(
        totalRuns: Int,
        findings: [Finding],
        dedupedCount: Int,
        perDetectorFlagRate: [String: Double],
        realCompletions: Int
    ) {
        self.totalRuns = totalRuns
        self.findings = findings
        self.dedupedCount = dedupedCount
        self.perDetectorFlagRate = perDetectorFlagRate
        self.realCompletions = realCompletions
    }

    /// `true` when the campaign ran at least one iteration but not a single
    /// turn reached a real completion. A clean `findings=0` report is only
    /// meaningful evidence of stability if the campaign actually drove
    /// generations — `runs=9626 findings=0` from a rig that silently no-oped
    /// every turn is evidence of nothing (ManifoldKit#2344). Zero real
    /// completions across an entire campaign is never a legitimate outcome:
    /// even the fastest, most boring backend produces *some* non-empty
    /// `"done"` completion on a benign prompt.
    public var isInert: Bool {
        totalRuns > 0 && realCompletions == 0
    }

    /// The process exit code a CLI driving a campaign to completion should
    /// use. `isInert` deliberately excludes `totalRuns == 0` (see its own doc
    /// comment — "ran but did nothing" and "never ran" are distinct failure
    /// classes, #2344 vs #2367), so a caller that checks `isInert` alone
    /// exits 0 on a campaign that never started (backend factory threw
    /// before the first iteration). This is the union both classes actually
    /// need, kept in one place — extracted as a pure function (ManifoldKit
    /// #2367 review) specifically so it can be unit-tested exhaustively
    /// without spawning the `fuzz-chat` process.
    ///
    /// `package`, not `public` (AGENTS.md's default): its only consumers are
    /// `fuzz-chat` and `ManifoldFuzzTests`, both in this package. manifold-mlx's
    /// `fuzz-mlx` driver imports `ManifoldFuzz` cross-package and reads
    /// `FuzzReport`'s other members, but has its own "findings are DATA — exit
    /// 0 regardless" exit policy and calls neither `isInert` nor this — so
    /// there is no cross-package consumer to keep this public for. Widen it
    /// later, with a stated reason, if one appears.
    package static func exitCode(for report: FuzzReport) -> Int32 {
        (report.isInert || report.totalRuns == 0) ? 1 : 0
    }
}

private extension Duration {
    var milliseconds: Double {
        let comps = self.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}

/// Deterministic xoshiro256** RNG. Reproducible across runs given the same seed.
public struct SeededRNG: RandomNumberGenerator {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    public init(seed: UInt64) {
        var s = seed == 0 ? 0xdeadbeefcafef00d : seed
        func splitmix() -> UInt64 {
            s = s &+ 0x9e3779b97f4a7c15
            var z = s
            z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
            return z ^ (z &>> 31)
        }
        state = (splitmix(), splitmix(), splitmix(), splitmix())
    }

    public mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 &<< 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x &<< k) | (x &>> (64 - k))
    }
}
