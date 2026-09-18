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
        /// Per-turn wall-clock bound on generation, in seconds. Mirrors
        /// `FuzzConfig.requestTimeout` — see `FuzzRunner.runSingle` for the
        /// single-turn twin of this wiring. Session scripts are just as
        /// exposed to a hung local-backend generation as single-turn runs,
        /// so every `.send`/`.regenerate` step is bounded the same way.
        public var requestTimeout: TimeInterval

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
            memoryBudgetBytes: UInt64? = nil,
            requestTimeout: TimeInterval = 90
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
            self.requestTimeout = requestTimeout
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

        var index = 0
        while index < script.steps.count {
            let step = script.steps[index]
            let t0 = ContinuousClock.now
            switch step {
            case .send(let text):
                messages.append(.init(role: "user", text: text))
                let pairedStop = script.steps.indices.contains(index + 1)
                    && script.steps[index + 1] == .stop
                let outcome: TurnOutcome
                if pairedStop {
                    outcome = await runTurnPairedWithStop(
                        messages: messages,
                        systemPrompt: script.systemPrompt,
                        requestGroupID: scriptSessionID,
                        stepIndex: index,
                        step: step
                    )
                } else {
                    outcome = .init(record: await runTurn(
                        messages: messages,
                        systemPrompt: script.systemPrompt,
                        requestGroupID: scriptSessionID,
                        stepIndex: index,
                        step: step
                    ))
                }
                // Append assistant reply (visible raw, even if empty — the
                // detectors care about the record field directly, but the
                // message array needs to stay consistent so subsequent
                // edit/delete indices are stable).
                messages.append(.init(role: "assistant", text: outcome.record.raw))
                steps.append(.init(
                    index: index,
                    step: step,
                    record: outcome.record,
                    timeline: .executed,
                    elapsedMs: elapsedMs(since: t0)
                ))
                if let stopObservation = outcome.stopObservation {
                    steps.append(.init(
                        index: index + 1,
                        step: .stop,
                        record: nil,
                        timeline: .stopRequested,
                        elapsedMs: outcome.stopElapsedMs,
                        stopObservation: stopObservation
                    ))
                    index += 2
                } else {
                    index += 1
                }

            case .regenerate:
                // Drop the most recent assistant message (if any) and re-run.
                if let last = messages.last, last.role == "assistant" {
                    messages.removeLast()
                }
                let pairedStop = script.steps.indices.contains(index + 1)
                    && script.steps[index + 1] == .stop
                let outcome: TurnOutcome
                if pairedStop {
                    outcome = await runTurnPairedWithStop(
                        messages: messages,
                        systemPrompt: script.systemPrompt,
                        requestGroupID: scriptSessionID,
                        stepIndex: index,
                        step: step
                    )
                } else {
                    outcome = .init(record: await runTurn(
                        messages: messages,
                        systemPrompt: script.systemPrompt,
                        requestGroupID: scriptSessionID,
                        stepIndex: index,
                        step: step
                    ))
                }
                messages.append(.init(role: "assistant", text: outcome.record.raw))
                steps.append(.init(
                    index: index,
                    step: step,
                    record: outcome.record,
                    timeline: .executed,
                    elapsedMs: elapsedMs(since: t0)
                ))
                if let stopObservation = outcome.stopObservation {
                    steps.append(.init(
                        index: index + 1,
                        step: .stop,
                        record: nil,
                        timeline: .stopRequested,
                        elapsedMs: outcome.stopElapsedMs,
                        stopObservation: stopObservation
                    ))
                    index += 2
                } else {
                    index += 1
                }

            case .stop:
                await MainActor.run { [service] in
                    service.stopGeneration()
                }
                steps.append(.init(
                    index: index,
                    step: step,
                    record: nil,
                    timeline: .stopRequested,
                    elapsedMs: elapsedMs(since: t0),
                    stopObservation: .init(
                        qualification: .notPairedWithTurn,
                        tailObservedBeforeStopReturned: "",
                        textObservedAfterStopReturned: ""
                    )
                ))
                index += 1

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
                index += 1

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
                index += 1
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
        step: SessionScript.Step,
        onVisibleToken: (@Sendable (String) -> Void)? = nil
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
            let (token, stream) = pair
            let requestTimeout = options.requestTimeout
            let maxOutputTokens = options.maxOutputTokens
            if options.backendName == "openai" {
                // See FuzzRunner.runSingle's twin of this branch: the cloud
                // path already has its own transport-level idle timeout
                // (which resets on activity), so a second wall-clock cap
                // here would additionally hard-cut a slow-but-continuously-
                // streaming completion the idle timeout correctly lets
                // finish.
                capture = await EventRecorder().consume(
                    stream,
                    maxOutputTokens: maxOutputTokens,
                    onVisibleToken: onVisibleToken
                )
            } else {
                capture = await GenerationTimeout.run(
                    .seconds(requestTimeout),
                    operation: {
                        await EventRecorder().consume(
                            stream,
                            maxOutputTokens: maxOutputTokens,
                            onVisibleToken: onVisibleToken
                        )
                    },
                    onTimeout: { [self] in
                        // Cancelling the operation task alone does not stop
                        // `InferenceService`'s in-flight generation — the
                        // request keeps running against the backend.
                        // `cancel(_:)` is the real stop path (mirrors
                        // FuzzRunner.runSingle's `stopGeneration()` call).
                        await self.cancelInFlight(token: token)
                        return EventRecorder.Capture(
                            events: [],
                            raw: "",
                            thinkingRaw: "",
                            thinkingParts: [],
                            thinkingCompleteCount: 0,
                            phase: "timeout",
                            error: "generation exceeded requestTimeout (\(requestTimeout)s)",
                            firstTokenMs: nil,
                            totalMs: self.elapsedMs(since: start),
                            peakBytes: memBefore,
                            promptTokens: nil,
                            completionTokens: nil,
                            stopReason: "timeout"
                        )
                    }
                )
            }
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
            toolDefinitions: options.toolDefinitions,
            truncated: capture.truncated
        )
    }

    /// Runs the existing one-turn path while the immediately following
    /// `.stop` step overlaps that turn. Waiting for the recorder's first
    /// visible-token observation proves the stream is active; the MainActor
    /// check and stop call are one non-suspending block, so a naturally ended
    /// turn is classified as unqualified instead of silently counting as
    /// cancellation coverage.
    private func runTurnPairedWithStop(
        messages: [ChatMessage],
        systemPrompt: String?,
        requestGroupID: UUID,
        stepIndex: Int,
        step: SessionScript.Step
    ) async -> TurnOutcome {
        let probe = TurnStopProbe()

        return await withTaskGroup(of: RunRecord.self) { group in
            group.addTask { [self] in
                let record = await self.runTurn(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    requestGroupID: requestGroupID,
                    stepIndex: stepIndex,
                    step: step,
                    onVisibleToken: { probe.observeVisibleToken($0) }
                )
                probe.completeTurn()
                return record
            }

            let milestone = await probe.waitForFirstVisibleTokenOrCompletion()
            let stopStart = ContinuousClock.now
            let wasInFlight = await MainActor.run { [service] in
                let active = service.isGenerating
                service.stopGeneration()
                return active
            }
            probe.markStopReturned(
                wasInFlight: wasInFlight,
                sawVisibleToken: milestone == .firstVisibleToken
            )
            let stopElapsedMs = elapsedMs(since: stopStart)

            let record = await group.next() ?? Self.cancelledTurnRecord(
                options: options,
                seed: seed,
                harness: harness,
                stepIndex: stepIndex,
                step: step
            )
            group.cancelAll()
            return TurnOutcome(
                record: record,
                stopObservation: probe.snapshot(),
                stopElapsedMs: stopElapsedMs
            )
        }
    }

    /// Defensive fallback for parent-task cancellation before the structured
    /// child can return its record. Normal enqueue failures/timeouts already
    /// return their own record from ``runTurn`` and never take this path.
    private static func cancelledTurnRecord(
        options: Options,
        seed: UInt64,
        harness: RunRecord.HarnessSnapshot,
        stepIndex: Int,
        step: SessionScript.Step
    ) -> RunRecord {
        RunRecord(
            runId: UUID().uuidString,
            ts: ISO8601DateFormatter().string(from: Date()),
            harness: harness,
            model: .init(
                backend: options.backendName,
                id: options.modelId,
                url: options.modelURL.absoluteString,
                fileSHA256: nil,
                tokenizerHash: nil,
                memoryBudgetBytes: options.memoryBudgetBytes
            ),
            config: .init(
                seed: seed,
                temperature: options.temperature,
                topP: options.topP,
                maxTokens: options.maxOutputTokens,
                systemPrompt: nil,
                contextLimit: options.contextLimit
            ),
            prompt: .init(
                corpusId: "session-script/\(step.opName)-\(stepIndex)",
                mutators: [],
                messages: []
            ),
            events: [],
            raw: "",
            rendered: "",
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: options.templateMarkers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: 0, tokensPerSec: nil),
            phase: "failed",
            error: "session script turn cancelled before capture completed",
            stopReason: "cancelled"
        )
    }

    private func tokensPerSec(_ c: EventRecorder.Capture) -> Double? {
        guard let completion = c.completionTokens,
              let firstToken = c.firstTokenMs,
              c.totalMs > firstToken else { return nil }
        return Double(completion) / ((c.totalMs - firstToken) / 1000.0)
    }

    /// Real stop path for a timed-out generation — `InferenceService` is
    /// `@MainActor`-isolated, so this hops there. Called from
    /// `GenerationTimeout`'s `onTimeout`, which cannot capture `service`
    /// directly (a non-`Sendable`, `@MainActor`-isolated type) inside its own
    /// non-isolated `@Sendable` closure; going through this actor-isolated
    /// method (actors are `Sendable`, so `self` capture is fine) sidesteps that.
    private func cancelInFlight(token: GenerationRequestToken) async {
        await MainActor.run { [service] in
            service.cancel(token)
        }
    }

    private nonisolated func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let comps = start.duration(to: ContinuousClock.now).components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}

private struct TurnOutcome: Sendable {
    let record: RunRecord
    let stopObservation: SessionCapture.StopObservation?
    let stopElapsedMs: Double

    init(
        record: RunRecord,
        stopObservation: SessionCapture.StopObservation? = nil,
        stopElapsedMs: Double = 0
    ) {
        self.record = record
        self.stopObservation = stopObservation
        self.stopElapsedMs = stopElapsedMs
    }
}

/// Lock-backed bridge between the runner task issuing `.stop` and the single
/// `EventRecorder` consumer observing the turn. "After stop" here always means
/// observed after `InferenceService.stopGeneration()` returned; buffered
/// stream events may have been emitted by the backend earlier, so the capture
/// deliberately does not claim backend-emission timing.
private final class TurnStopProbe: @unchecked Sendable {
    enum Milestone: Sendable, Equatable {
        case firstVisibleToken
        case completedWithoutVisibleToken
    }

    private static let tailLimit = 1_024

    private let lock = NSLock()
    private let milestones: AsyncStream<Milestone>
    private let milestoneContinuation: AsyncStream<Milestone>.Continuation
    private var sawVisibleToken = false
    private var stopReturned = false
    private var qualification: SessionCapture.StopQualification?
    private var tailObservedBeforeStopReturned = ""
    private var textObservedAfterStopReturned = ""

    init() {
        let pair = AsyncStream<Milestone>.makeStream(bufferingPolicy: .unbounded)
        milestones = pair.stream
        milestoneContinuation = pair.continuation
    }

    func waitForFirstVisibleTokenOrCompletion() async -> Milestone? {
        var iterator = milestones.makeAsyncIterator()
        return await iterator.next()
    }

    func observeVisibleToken(_ text: String) {
        var shouldSignal = false
        lock.lock()
        if stopReturned {
            appendBounded(text, to: &textObservedAfterStopReturned)
        } else {
            appendBounded(text, to: &tailObservedBeforeStopReturned)
        }
        if !sawVisibleToken {
            sawVisibleToken = true
            shouldSignal = true
        }
        lock.unlock()

        if shouldSignal {
            milestoneContinuation.yield(.firstVisibleToken)
        }
    }

    func completeTurn() {
        lock.lock()
        let shouldSignalCompletion = !sawVisibleToken
        lock.unlock()

        if shouldSignalCompletion {
            milestoneContinuation.yield(.completedWithoutVisibleToken)
        }
        milestoneContinuation.finish()
    }

    func markStopReturned(wasInFlight: Bool, sawVisibleToken: Bool) {
        lock.lock()
        stopReturned = true
        if !sawVisibleToken {
            qualification = .noVisibleContent
        } else if wasInFlight {
            qualification = .inFlight
        } else {
            qualification = .completedBeforeStop
        }
        lock.unlock()
    }

    func snapshot() -> SessionCapture.StopObservation {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            qualification: qualification ?? .cancelledBeforeObservation,
            tailObservedBeforeStopReturned: tailObservedBeforeStopReturned,
            textObservedAfterStopReturned: textObservedAfterStopReturned
        )
    }

    private func appendBounded(_ text: String, to buffer: inout String) {
        buffer += text
        if buffer.count > Self.tailLimit {
            buffer.removeFirst(buffer.count - Self.tailLimit)
        }
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

    /// `true` for the two step kinds that actually drive an `InferenceService.enqueue`
    /// call (and therefore must produce a ``SessionCapture/StepResult/record``).
    /// `.stop`/`.edit`/`.delete` legitimately carry a `nil` record — this
    /// distinguishes that from the anomaly a `.send`/`.regenerate` step with a
    /// `nil` record would represent (see `SessionFuzzRunner`'s `missingRecordCount`).
    var isTurnStep: Bool {
        switch self {
        case .send, .regenerate: return true
        case .stop, .edit, .delete: return false
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
        let stopObservation: StopObservation?

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
            self.stopObservation = nil
        }

        init(
            index: Int,
            step: SessionScript.Step,
            record: RunRecord?,
            timeline: TimelineEvent,
            elapsedMs: Double,
            stopObservation: StopObservation
        ) {
            self.index = index
            self.step = step
            self.record = record
            self.timeline = timeline
            self.elapsedMs = elapsedMs
            self.stopObservation = stopObservation
        }
    }

    enum StopQualification: Sendable, Equatable {
        case inFlight
        case completedBeforeStop
        case noVisibleContent
        case notPairedWithTurn
        case cancelledBeforeObservation
    }

    struct StopObservation: Sendable, Equatable {
        let qualification: StopQualification
        let tailObservedBeforeStopReturned: String
        let textObservedAfterStopReturned: String
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
