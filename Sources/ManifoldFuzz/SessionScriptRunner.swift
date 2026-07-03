import Foundation
import ManifoldInference

/// Interprets a ``SessionScript`` against a real ``InferenceService``,
/// capturing each turn's ``RunRecord`` and a compact queue timeline for
/// multi-turn detectors.
///
/// The runner owns its own local message array; `edit`/`delete` mutate that
/// array but do not themselves drive the service. `send` and `regenerate`
/// call `InferenceService.enqueue` and consume the stream via
/// `EventRecorder`. `stop` calls `InferenceService.stopGeneration`.
///
/// Returns a ``SessionCapture`` with one ``SessionCapture/StepResult`` per
/// script step. The step result carries the (optional) ``RunRecord`` from
/// executing that step plus a timeline entry describing what happened.
public actor SessionScriptRunner {

    public struct Options: Sendable {
        /// Handle metadata copied into each per-step ``RunRecord`` so detectors
        /// continue to see backend/model identifiers (they gate on these to
        /// dedup findings per-model).
        public var modelId: String
        public var modelURL: URL
        public var backendName: String
        public var templateMarkers: RunRecord.MarkerSnapshot?
        /// Generation parameters used for every `.send` / `.regenerate` step.
        public var temperature: Float
        public var topP: Float
        public var repeatPenalty: Float
        public var maxOutputTokens: Int?
        /// Request group ID applied to every enqueue. When the script carries
        /// multiple logical sessions, use ``SessionScriptRunner/execute(_:)``
        /// per-script and compose captures externally; within a single script
        /// the `sessionLabel` field pins the id so the service's request-scoped
        /// discard/cancel semantics apply.
        public var requestGroupID: UUID?
        /// Tool definitions advertised on every `.send` / `.regenerate` step.
        /// Empty by default (no tools). Pairs with the `--tools` CLI flag via
        /// `SessionFuzzRunner`, mirroring the single-turn `FuzzRunner` path.
        public var toolDefinitions: [ToolDefinition]
        /// The backend's context-window limit in tokens, when known. Feeds
        /// `RunRecord.ConfigSnapshot.contextLimit` — see `FuzzRunner.runSingle`
        /// for the single-turn twin of this wiring.
        public var contextLimit: Int?
        /// Per-model memory budget in bytes, when the factory can supply one.
        /// Feeds `RunRecord.ModelSnapshot.memoryBudgetBytes`.
        public var memoryBudgetBytes: UInt64?

        public init(
            modelId: String = "mock-model",
            modelURL: URL = URL(string: "mem://session")!,
            backendName: String = "mock",
            templateMarkers: RunRecord.MarkerSnapshot? = nil,
            temperature: Float = 0.7,
            topP: Float = 0.9,
            repeatPenalty: Float = 1.1,
            maxOutputTokens: Int? = 256,
            requestGroupID: UUID? = nil,
            toolDefinitions: [ToolDefinition] = [],
            contextLimit: Int? = nil,
            memoryBudgetBytes: UInt64? = nil
        ) {
            self.modelId = modelId
            self.modelURL = modelURL
            self.backendName = backendName
            self.templateMarkers = templateMarkers
            self.temperature = temperature
            self.topP = topP
            self.repeatPenalty = repeatPenalty
            self.maxOutputTokens = maxOutputTokens
            self.requestGroupID = requestGroupID
            self.toolDefinitions = toolDefinitions
            self.contextLimit = contextLimit
            self.memoryBudgetBytes = memoryBudgetBytes
        }
    }

    private let service: InferenceService
    private let options: Options
    private let seed: UInt64
    private let harness: RunRecord.HarnessSnapshot

    public init(
        service: InferenceService,
        options: Options = .init(),
        seed: UInt64 = 0,
        harness: RunRecord.HarnessSnapshot? = nil
    ) {
        self.service = service
        self.options = options
        self.seed = seed
        self.harness = harness ?? Self.defaultHarness()
    }

    private static func defaultHarness() -> RunRecord.HarnessSnapshot {
        HarnessMetadata.snapshot(repoRoot: nil)
    }

    /// Executes the script end-to-end, returning one ``SessionCapture`` with
    /// per-step results. The runner does not propagate errors — an enqueue
    /// failure is captured on the step as a failed ``RunRecord`` with
    /// `phase="failed"`, matching the single-turn `FuzzRunner.runSingle`
    /// convention.
    public func execute(_ script: SessionScript) async -> SessionCapture {
        // Local message array: the canonical user/assistant history we feed
        // into the next enqueue. Edits/deletes mutate it in-place.
        var messages: [ChatMessage] = []
        var steps: [SessionCapture.StepResult] = []
        let scriptSessionID: UUID = options.requestGroupID ?? UUID()

        for (index, step) in script.steps.enumerated() {
            let t0 = ContinuousClock.now
            switch step {
            case .send(let text):
                messages.append(.init(role: "user", text: text))
                let record = await runTurn(
                    messages: messages,
                    systemPrompt: script.systemPrompt,
                    requestGroupID: scriptSessionID,
                    stepIndex: index,
                    step: step
                )
                // Append assistant reply (visible raw, even if empty — the
                // detectors care about the record field directly, but the
                // message array needs to stay consistent so subsequent
                // edit/delete indices are stable).
                messages.append(.init(role: "assistant", text: record.raw))
                steps.append(.init(
                    index: index,
                    step: step,
                    record: record,
                    timeline: .executed,
                    elapsedMs: elapsedMs(since: t0)
                ))

            case .regenerate:
                // Drop the most recent assistant message (if any) and re-run.
                if let last = messages.last, last.role == "assistant" {
                    messages.removeLast()
                }
                let record = await runTurn(
                    messages: messages,
                    systemPrompt: script.systemPrompt,
                    requestGroupID: scriptSessionID,
                    stepIndex: index,
                    step: step
                )
                messages.append(.init(role: "assistant", text: record.raw))
                steps.append(.init(
                    index: index,
                    step: step,
                    record: record,
                    timeline: .executed,
                    elapsedMs: elapsedMs(since: t0)
                ))

            case .stop:
                await MainActor.run { [service] in
                    service.stopGeneration()
                }
                steps.append(.init(
                    index: index,
                    step: step,
                    record: nil,
                    timeline: .stopRequested,
                    elapsedMs: elapsedMs(since: t0)
                ))

            case .edit(let idx, let newText):
                if messages.indices.contains(idx) {
                    messages[idx] = .init(role: messages[idx].role, text: newText)
                    steps.append(.init(
                        index: index,
                        step: step,
                        record: nil,
                        timeline: .edited,
                        elapsedMs: elapsedMs(since: t0)
                    ))
                } else {
                    steps.append(.init(
                        index: index,
                        step: step,
                        record: nil,
                        timeline: .indexOutOfRange,
                        elapsedMs: elapsedMs(since: t0)
                    ))
                }

            case .delete(let idx):
                if messages.indices.contains(idx) {
                    messages.remove(at: idx)
                    steps.append(.init(
                        index: index,
                        step: step,
                        record: nil,
                        timeline: .deleted,
                        elapsedMs: elapsedMs(since: t0)
                    ))
                } else {
                    steps.append(.init(
                        index: index,
                        step: step,
                        record: nil,
                        timeline: .indexOutOfRange,
                        elapsedMs: elapsedMs(since: t0)
                    ))
                }
            }
        }

        return SessionCapture(
            script: script,
            sessionID: scriptSessionID,
            steps: steps
        )
    }

    private func runTurn(
        messages: [ChatMessage],
        systemPrompt: String?,
        requestGroupID: UUID,
        stepIndex: Int,
        step: SessionScript.Step
    ) async -> RunRecord {
        let memBefore = AppMemoryUsage.currentBytes()
        let start = ContinuousClock.now

        let tuples: [(role: String, content: String)] = messages.map { ($0.role, $0.text) }
        // Same character-based estimate `FuzzRunner.runSingle` uses — populates
        // `ContextExhaustionSilentDetector`'s suppression guard on this path too
        // (#39 in the 2026-07 inert-code audit).
        let estimatedPromptTokens = ContextWindowManager.estimateTokenCount(systemPrompt ?? "")
            + tuples.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1.content) }

        // Enqueue on MainActor (InferenceService is MainActor-isolated).
        let enqueueResult: Result<(GenerationRequestToken, GenerationStream), Error> = await MainActor.run { [service, options] in
            do {
                let messageValues: [Message] = tuples.map { tuple in
                    switch tuple.role {
                    case "system": return .system(tuple.content)
                    case "assistant": return .assistant(tuple.content)
                    default: return .user(tuple.content)
                    }
                }
                var cfg = GenerationConfig(
                    temperature: options.temperature,
                    topP: options.topP,
                    repeatPenalty: options.repeatPenalty,
                    maxOutputTokens: options.maxOutputTokens
                )
                if !options.toolDefinitions.isEmpty {
                    cfg.tools = options.toolDefinitions
                    cfg.toolChoice = .auto
                }
                let r = try service.enqueue(
                    messages: messageValues,
                    systemPrompt: systemPrompt,
                    config: cfg,
                    priority: .normal,
                    requestGroupID: requestGroupID
                )
                return .success((r.token, r.stream))
            } catch {
                return .failure(error)
            }
        }

        let capture: EventRecorder.Capture
        switch enqueueResult {
        case .failure(let error):
            capture = EventRecorder.Capture(
                events: [],
                raw: "",
                thinkingRaw: "",
                thinkingParts: [],
                thinkingCompleteCount: 0,
                phase: "failed",
                error: String(describing: error),
                firstTokenMs: nil,
                totalMs: elapsedMs(since: start),
                peakBytes: memBefore,
                promptTokens: nil,
                completionTokens: nil,
                stopReason: "error"
            )
        case .success(let pair):
            let (_, stream) = pair
            capture = await EventRecorder().consume(stream, maxOutputTokens: options.maxOutputTokens)
        }

        let memAfter = AppMemoryUsage.currentBytes()

        let lastUser = messages.last(where: { $0.role == "user" })?.text ?? ""
        let corpusId = "session-script/\(step.opName)-\(stepIndex)"

        return RunRecord(
            runId: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            harness: harness,
            model: RunRecord.ModelSnapshot(
                backend: options.backendName,
                id: options.modelId,
                url: options.modelURL.absoluteString,
                fileSHA256: nil,
                tokenizerHash: nil,
                memoryBudgetBytes: options.memoryBudgetBytes
            ),
            config: RunRecord.ConfigSnapshot(
                seed: seed,
                temperature: options.temperature,
                topP: options.topP,
                maxTokens: options.maxOutputTokens,
                systemPrompt: systemPrompt,
                toolChoice: options.toolDefinitions.isEmpty ? nil : encodeToolChoice(.auto),
                contextLimit: options.contextLimit
            ),
            prompt: RunRecord.PromptSnapshot(
                corpusId: corpusId,
                mutators: [],
                messages: [.init(role: "user", text: lastUser)],
                estimatedPromptTokens: estimatedPromptTokens
            ),
            events: capture.events,
            raw: capture.raw,
            rendered: MarkdownRendering.renderToVisibleString(capture.raw),
            thinkingRaw: capture.thinkingRaw,
            thinkingParts: capture.thinkingParts,
            thinkingCompleteCount: capture.thinkingCompleteCount,
            templateMarkers: options.templateMarkers,
            memory: RunRecord.MemorySnapshot(
                beforeBytes: memBefore,
                peakBytes: capture.peakBytes,
                afterBytes: memAfter
            ),
            timing: RunRecord.TimingSnapshot(
                firstTokenMs: capture.firstTokenMs,
                totalMs: capture.totalMs,
                tokensPerSec: tokensPerSec(capture)
            ),
            phase: capture.phase,
            error: capture.error,
            stopReason: capture.stopReason,
            toolCalls: capture.toolCalls,
            toolResults: capture.toolResults,
            toolDefinitions: options.toolDefinitions
        )
    }

    private func tokensPerSec(_ c: EventRecorder.Capture) -> Double? {
        guard let completion = c.completionTokens,
              let firstToken = c.firstTokenMs,
              c.totalMs > firstToken else { return nil }
        return Double(completion) / ((c.totalMs - firstToken) / 1000.0)
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let comps = start.duration(to: ContinuousClock.now).components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}

/// Minimal internal message model for the runner. We don't reuse
/// `RunRecord.PromptSnapshot.Message` because that type's purpose is on-disk
/// snapshotting — the runner's working set keeps the contract looser so we
/// can mutate it by index without coupling to the snapshot schema.
public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let text: String
    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public extension SessionScript.Step {
    /// Compact one-word label used as a corpus id component and in trigger
    /// strings.
    var opName: String {
        switch self {
        case .send: return "send"
        case .stop: return "stop"
        case .edit: return "edit"
        case .regenerate: return "regenerate"
        case .delete: return "delete"
        }
    }
}

/// The output of ``SessionScriptRunner/execute(_:)``. Composes a sequence of
/// ``StepResult`` so multi-turn detectors can inspect cross-turn state.
public struct SessionCapture: Sendable {
    public let script: SessionScript
    public let sessionID: UUID
    public let steps: [StepResult]

    public init(script: SessionScript, sessionID: UUID, steps: [StepResult]) {
        self.script = script
        self.sessionID = sessionID
        self.steps = steps
    }

    /// Convenience: only the steps that actually drove a generation turn,
    /// in script order. Detectors that compare turn N vs turn N-1 use this.
    public var turnRecords: [RunRecord] {
        steps.compactMap { $0.record }
    }

    public struct StepResult: Sendable {
        public let index: Int
        public let step: SessionScript.Step
        public let record: RunRecord?
        public let timeline: TimelineEvent
        public let elapsedMs: Double

        public init(
            index: Int,
            step: SessionScript.Step,
            record: RunRecord?,
            timeline: TimelineEvent,
            elapsedMs: Double
        ) {
            self.index = index
            self.step = step
            self.record = record
            self.timeline = timeline
            self.elapsedMs = elapsedMs
        }
    }

    /// Compact queue-timeline classification for a script step. Detectors
    /// read this to disambiguate (e.g., `stopRequested` before turn-2 is the
    /// signal for ``CancellationRaceDetector``).
    public enum TimelineEvent: String, Sendable {
        case executed           // send/regenerate completed via enqueue
        case stopRequested      // stop step fired stopGeneration
        case edited             // edit mutated the message array
        case deleted            // delete mutated the message array
        case indexOutOfRange    // edit/delete with an invalid index
    }
}
