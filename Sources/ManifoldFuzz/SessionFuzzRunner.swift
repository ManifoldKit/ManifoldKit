import Foundation
import ManifoldInference

/// Multi-turn fuzz driver. Sibling of ``FuzzRunner``; the single-turn runner
/// is untouched.
///
/// Iterates each bundled ``SessionScript`` through a fresh backend handle
/// (obtained from the same ``FuzzBackendFactory`` the single-turn runner
/// uses), wraps the backend in an ``InferenceService``, and drives the
/// script via ``SessionScriptRunner``. Each step's ``RunRecord`` is run
/// through every single-turn detector; each full ``SessionCapture`` is
/// run through every ``SessionDetector``. Findings are written to the same
/// ``FindingsSink`` so the CLI's `tmp/fuzz/findings/` directory merges
/// cleanly with single-turn runs.
public actor SessionFuzzRunner {

    private let config: FuzzConfig
    private let factory: any FuzzBackendFactory
    private let sink: FindingsSink
    private let scripts: [SessionScript]
    /// `@MainActor` required: `InferenceService.init` is main-actor-isolated, so any
    /// closure that constructs one must hop to main.
    private let serviceFactory: @MainActor @Sendable (any InferenceBackend, String) -> InferenceService

    public init(
        config: FuzzConfig,
        factory: any FuzzBackendFactory,
        scripts: [SessionScript]? = nil,
        // @MainActor required: closure instantiates a @MainActor-isolated InferenceService.
        serviceFactory: (@MainActor @Sendable (any InferenceBackend, String) -> InferenceService)? = nil
    ) {
        self.config = config
        self.factory = factory
        self.sink = FindingsSink(outputDir: config.outputDir)
        self.scripts = scripts ?? SessionScript.loadAll()
        self.serviceFactory = serviceFactory ?? SessionFuzzRunner.defaultServiceFactory
    }

    /// Default service factory. Uses `InferenceService(backend:name:)` from
    /// the `#if DEBUG` convenience initializer. `swift run` and `swift test`
    /// both build in debug by default, so this is safe; for release builds
    /// the caller must supply a custom `serviceFactory` that wires a factory
    /// via `registerBackendFactory`.
    // @MainActor required: constructs a @MainActor-isolated InferenceService.
    @MainActor
    public static func defaultServiceFactory(_ backend: any InferenceBackend, _ name: String) -> InferenceService {
        #if DEBUG
        return InferenceService(backend: backend, name: name)
        #else
        // Release fallback: caller must override. We still return something
        // valid so the harness doesn't crash — the generation will fail with
        // "no model loaded" which the per-step record captures cleanly.
        return InferenceService()
        #endif
    }

    public func run(reporter: TerminalReporter) async -> FuzzReport {
        guard !scripts.isEmpty else {
            await reporter.error("No session scripts available — Resources/session_scripts/*.json missing?")
            return FuzzReport(totalRuns: 0, findings: [], dedupedCount: 0, perDetectorFlagRate: [:], realCompletions: 0)
        }

        let singleDetectors = DetectorRegistry.resolve(config.detectorFilter)
        let sessionDetectors = SessionDetectorRegistry.resolve(config.detectorFilter)

        let detectorIds = singleDetectors.map(\.id) + sessionDetectors.map(\.id)

        // Prime the factory and print preflight.
        let primeHandle: FuzzRunner.BackendHandle
        do {
            primeHandle = try await factory.makeHandle()
        } catch {
            await reporter.error("Backend factory failed: \(error)")
            return FuzzReport(totalRuns: 0, findings: [], dedupedCount: 0, perDetectorFlagRate: [:], realCompletions: 0)
        }
        await reporter.preflight(backend: primeHandle.backendName, model: primeHandle.modelId, detectors: detectorIds)

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
        var pendingHandle: FuzzRunner.BackendHandle? = primeHandle
        // Campaign-wide integrity counters (ManifoldKit#2344's floor-rate
        // guard). `executedTurnSteps` is every `.send`/`.regenerate` step the
        // script called for; `missingRecordCount` is how many of those never
        // even produced a `RunRecord` (the exact silent-skip failure mode the
        // issue found — should be impossible, but a regression here must be
        // loud, not swallowed by the `guard let record = step.record else {
        // continue }` below). `realCompletions` is how many reached
        // `phase == "done"`, i.e. an actual generation against the backend.
        var executedTurnSteps = 0
        var missingRecordCount = 0
        var realCompletions = 0

        // Each "iteration" = one full session-script execution. We loop the
        // whole corpus until the time/iteration budget is spent, mirroring
        // the single-turn runner's cadence.
        var scriptCursor = 0
        while iter < iterCap {
            if let deadline, ContinuousClock.now >= deadline { break }
            iter += 1
            let script = scripts[scriptCursor % scripts.count]
            scriptCursor += 1

            let handle: FuzzRunner.BackendHandle
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

            await reporter.iterationStart(iter: iter, model: handle.modelId, temp: 0.7, totalFindings: totalFindings)

            // Run one script, gather capture.
            let capture = await runScript(script, handle: handle)

            // Per-step single-turn detectors.
            var iterationFindings: [Finding] = []
            for step in capture.steps {
                if step.step.isTurnStep { executedTurnSteps += 1 }
                guard let record = step.record else {
                    if step.step.isTurnStep { missingRecordCount += 1 }
                    continue
                }
                if record.phase == "done" { realCompletions += 1 }
                for d in singleDetectors {
                    iterationFindings.append(contentsOf: d.inspect(record))
                }
            }
            // Whole-capture session detectors.
            for d in sessionDetectors {
                iterationFindings.append(contentsOf: d.inspect([capture]))
            }

            await reporter.iterationEnd()

            if iterationFindings.isEmpty {
                await sink.noteEmptyRun()
            } else {
                totalFindings += iterationFindings.count
                for f in iterationFindings {
                    perDetector[f.detectorId, default: 0] += 1
                    await reporter.finding(f)
                }
                // Record one representative record per finding. Prefer the
                // last executed turn so detectors that fire on cross-turn
                // state still get a record.json to repro against.
                let representative = capture.turnRecords.last ?? fallbackRecord(for: capture, handle: handle)
                await sink.recordRun(representative, findings: iterationFindings)
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
                "session-scripts campaign ran \(iter) iteration(s) covering \(executedTurnSteps) "
                + "send/regenerate step(s), of which \(missingRecordCount) never produced a "
                + "RunRecord at all, and NOT ONE of the rest reached a real completion "
                + "(RunRecord.phase == \"done\"). A clean \"findings=0\" report from this run is "
                + "not evidence of stability; it is evidence the rig never drove the backend. "
                + "See ManifoldKit#2344."
            )
        }
        await reporter.finalSummary(report: report)
        return report
    }

    private func runScript(_ script: SessionScript, handle: FuzzRunner.BackendHandle) async -> SessionCapture {
        let service = await MainActor.run { [serviceFactory] in
            serviceFactory(handle.backend, handle.backendName)
        }
        // Mirrors the single-turn `FuzzRunner.runSingle` wiring: `--tools`
        // injects the same `SyntheticToolset` on every turn so
        // `ToolCallValidityDetector` has invariants to check on this path too
        // (previously silently ignored here — #45 in the 2026-07 inert-code audit).
        let opts = SessionScriptRunner.Options(
            modelId: handle.modelId,
            modelURL: handle.modelURL,
            backendName: handle.backendName,
            templateMarkers: handle.templateMarkers,
            maxOutputTokens: 256,
            toolDefinitions: config.tools ? SyntheticToolset.definitions : [],
            contextLimit: handle.backend.capabilities.contextWindowSize,
            memoryBudgetBytes: handle.memoryBudgetBytes,
            requestTimeout: config.requestTimeout
        )
        let runner = SessionScriptRunner(
            service: service,
            options: opts,
            seed: config.seed
        )
        return await runner.execute(script)
    }

    /// When a script produced no turn records (only edits/deletes, never
    /// reached a `send`), still write a skeleton record so the sink has a
    /// valid path to reproduce.
    private func fallbackRecord(for capture: SessionCapture, handle: FuzzRunner.BackendHandle) -> RunRecord {
        RunRecord(
            runId: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            harness: HarnessMetadata.snapshot(repoRoot: nil),
            model: .init(
                backend: handle.backendName,
                id: handle.modelId,
                url: handle.modelURL.absoluteString,
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: config.seed,
                temperature: 0.7,
                topP: 0.9,
                maxTokens: 256,
                systemPrompt: capture.script.systemPrompt
            ),
            prompt: .init(
                corpusId: "session-script/\(capture.script.id)",
                mutators: [],
                messages: []
            ),
            events: [],
            raw: "",
            rendered: "",
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: handle.templateMarkers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: 0, tokensPerSec: nil),
            phase: "done",
            error: nil,
            stopReason: "naturalStop"
        )
    }
}
