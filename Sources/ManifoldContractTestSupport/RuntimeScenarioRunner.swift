#if DEBUG
import Foundation
import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Executes a ``RuntimeScenario`` in either scripted (hermetic CI) or live
/// (real backend) mode and returns the recorded trace + assertion outcomes.
///
/// In `.scripted` mode the runner wires up a ``ScriptedGenerationBackend``
/// populated from ``RuntimeScenario/scriptedTurns`` and records the full
/// ``ConversationEvent`` trace via ``ConversationEventRecorder``.
///
/// In `.live(_:)` mode the runner wires up the caller-supplied backend.
/// Only the structural ``RuntimeScenario/expectedSubsequence`` is checked —
/// token content is nondeterministic in live runs.
///
/// Both modes use a bare ``ConversationRuntime`` with an in-memory
/// ``MessageStore`` so no SwiftData stack is required.
@MainActor
public enum RuntimeScenarioRunner {

    public enum RunMode {
        /// Hermetic CI run — uses `ScriptedGenerationBackend` from the scenario's
        /// `scriptedTurns`. Asserts the recorded trace satisfies `expectedSubsequence`.
        case scripted
        /// Live run — uses the supplied backend. Asserts only the structural
        /// subsequence; token content is not checked.
        case live(backend: any InferenceBackend)
    }

    public struct Result: Sendable {
        /// The scenario that was run.
        public let scenario: RuntimeScenario
        /// The mode used.
        public let mode: RunModeKind
        /// Full event trace recorded by ``ConversationEventRecorder``.
        public let trace: ConversationEventTrace
        /// `true` when ``RuntimeScenario/expectedSubsequence`` is satisfied.
        public let subsequencePassed: Bool
        /// Diagnostic string when ``subsequencePassed`` is `false`.
        public let subsequenceFailureReason: String?
        /// All messages left in the in-memory store after the run, oldest-first.
        ///
        /// Lets callers make structural assertions about the produced records —
        /// for example that at least one assistant message carries a
        /// ``Citation`` when a ``RAGService`` was wired in (#1575).
        public let producedMessages: [ChatMessage]

        public enum RunModeKind: Sendable { case scripted, live }
    }

    /// Runs `scenario` in `mode` and returns the result.
    ///
    /// Does not call `XCTFail` — callers (typically XCTest methods) should
    /// call ``assert(result:file:line:)`` to surface failures.
    /// Runs `scenario` in `mode`, optionally wiring a real ``RAGService`` and an
    /// override pre-turn compression policy into the runtime.
    ///
    /// - Parameters:
    ///   - ragService: When non-`nil`, the runtime queries it before each turn
    ///     and attaches the resulting ``Citation`` list to the assistant
    ///     message — the live-RAG demo path (#1575). When `nil`, behaviour is
    ///     identical to the legacy retrieval-free run.
    ///   - preTurnCompressionPolicy: When non-`nil`, overrides the scenario's
    ///     own ``RuntimeScenario/preTurnCompressionPolicy``. Lets a live run
    ///     drive context-window-based compression off real token usage instead
    ///     of the scenario's deterministic fixed-count policy.
    public static func run(
        _ scenario: RuntimeScenario,
        mode: RunMode = .scripted,
        ragService: RAGService? = nil,
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil
    ) async throws -> Result {
        let backend: any InferenceBackend
        let scriptedBackend: ScriptedGenerationBackend?
        let modeKind: Result.RunModeKind

        switch mode {
        case .scripted:
            let scripted = ScriptedGenerationBackend(turns: scenario.scriptedTurns)
            // ScriptedGenerationBackend defaults isModelLoaded = true so no
            // extra step is needed; mark it explicit for clarity.
            scripted.isModelLoaded = true
            backend = scripted
            scriptedBackend = scripted
            modeKind = .scripted
        case .live(let liveBackend):
            backend = liveBackend
            scriptedBackend = nil
            modeKind = .live
        }

        // Tool round-trip scenarios register executors so the dispatch loop has
        // a registry to route the model-emitted tool call through. Send-only
        // scenarios pass nil, matching the legacy no-tool path.
        let toolRegistry: ToolRegistry?
        if scenario.toolExecutors.isEmpty {
            toolRegistry = nil
        } else {
            let registry = ToolRegistry()
            for tool in scenario.toolExecutors {
                registry.register(tool)
            }
            toolRegistry = registry
        }

        let store = ScenarioMessageStore()
        let inferenceService = InferenceService(
            backend: backend,
            name: "ScenarioRunner-\(scenario.id)",
            toolRegistry: toolRegistry
        )
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inferenceService,
            ragService: ragService,
            preTurnCompressionPolicy: preTurnCompressionPolicy ?? scenario.preTurnCompressionPolicy
        )

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let sessionID = UUID()
        for turn in scenario.turns {
            try await runTurn(
                turn,
                runtime: runtime,
                scriptedBackend: scriptedBackend,
                sessionID: sessionID
            )
        }

        drainTask.cancel()
        await drainTask.value

        let trace = await ConversationEventTrace(recorder: recorder)
        let (passed, reason) = checkSubsequence(trace.kinds, against: scenario.expectedSubsequence)

        let producedMessages: [ChatMessage]
        do {
            producedMessages = try await store.fetchMessages(for: sessionID)
        } catch {
            // Surface store-read failures instead of silently swallowing them —
            // a failed fetch would otherwise mask citation/compression assertions
            // in live runs (SilentCatchAuditTest).
            XCTFail("RuntimeScenarioRunner: failed to fetch produced messages: \(error)")
            producedMessages = []
        }

        return Result(
            scenario: scenario,
            mode: modeKind,
            trace: trace,
            subsequencePassed: passed,
            subsequenceFailureReason: reason,
            producedMessages: producedMessages
        )
    }

    // MARK: - Per-turn drive

    /// Number of permits flooded into the emission gate after a cancel lands,
    /// so the scripted backend's producer task drains its remaining tokens
    /// instead of parking forever on the gate. Comfortably larger than any
    /// scripted cancel turn's token count.
    private static let gateDrainPermits = 64

    /// Drives a single ``RuntimeScenario/ScenarioTurn`` to terminal completion.
    private static func runTurn(
        _ turn: RuntimeScenario.ScenarioTurn,
        runtime: ConversationRuntime,
        scriptedBackend: ScriptedGenerationBackend?,
        sessionID: UUID
    ) async throws {
        let config: TurnConfig
        if let limit = turn.streamingBatchCharacterLimit {
            config = TurnConfig(streamingBatchCharacterLimit: limit)
        } else {
            config = TurnConfig()
        }

        let kind: TurnKind
        switch turn.action {
        case let .send(text): kind = .send(text: text)
        case .regenerate:     kind = .regenerate
        }
        let input = TurnInput(sessionID: sessionID, kind: kind, config: config)

        // Plain turn: launch and await the reliable per-turn outcome.
        guard let cancelAfter = turn.cancelAfterTokens else {
            let handle = try await runtime.processTurnWithOutcome(input)
            _ = await handle?.outcome
            return
        }

        // Cancellation turn. The scripted backend's emission gate makes the
        // cancel point deterministic: tokens are released one at a time, and we
        // issue cancel the moment we have observed `cancelAfter` of them — before
        // the terminal stream event can be produced.
        guard let scriptedBackend else {
            // Live mode has no emission gate; fall back to a best-effort drive
            // that still issues cancel after observing the Nth token. Live
            // cancellation is inherently racy and not part of the CI gate.
            try await driveCancelWithoutGate(
                input,
                cancelAfter: cancelAfter,
                runtime: runtime
            )
            return
        }

        let gate = TokenEmissionGate()
        scriptedBackend.tokenEmissionGate = gate
        defer { scriptedBackend.tokenEmissionGate = nil }

        let tap = runtime.addEventTap()
        let handle = try await runtime.processTurnWithOutcome(input)
        guard let handle else { return }

        let driver = Task { @MainActor in
            var seen = 0
            for await event in tap {
                if case .tokenEmitted = event {
                    seen += 1
                    if seen == cancelAfter {
                        await runtime.cancel(handle.streamHandle)
                        // Flood permits so the gated producer task can drain and
                        // finish rather than parking on a never-advanced gate.
                        for _ in 0..<gateDrainPermits { await gate.advance() }
                    }
                }
                if case .streamFinished = event { break }
                if case .errorRaised = event { break }
            }
        }

        // Release exactly `cancelAfter` tokens so the driver observes them and
        // triggers the cancel. The producer parks on the next token until the
        // driver floods the gate post-cancel.
        for _ in 0..<cancelAfter { await gate.advance() }
        _ = await handle.outcome
        await driver.value
    }

    /// Best-effort cancellation for live mode (no emission gate). Not used by
    /// the scripted CI gate.
    private static func driveCancelWithoutGate(
        _ input: TurnInput,
        cancelAfter: Int,
        runtime: ConversationRuntime
    ) async throws {
        let tap = runtime.addEventTap()
        let handle = try await runtime.processTurnWithOutcome(input)
        guard let handle else { return }
        let driver = Task { @MainActor in
            var seen = 0
            for await event in tap {
                if case .tokenEmitted = event {
                    seen += 1
                    if seen == cancelAfter {
                        await runtime.cancel(handle.streamHandle)
                    }
                }
                if case .streamFinished = event { break }
                if case .errorRaised = event { break }
            }
        }
        _ = await handle.outcome
        await driver.value
    }

    /// Calls `XCTFail` if `result.subsequencePassed` is `false`.
    public static func assert(
        result: Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !result.subsequencePassed, let reason = result.subsequenceFailureReason else { return }
        XCTFail("Scenario '\(result.scenario.id)' failed: \(reason)", file: file, line: line)
    }

    // MARK: - Subsequence check (mirrors XCTAssertEventSubsequence logic)

    private static func checkSubsequence(
        _ kinds: [ConversationEventKind],
        against expected: [ConversationEventKind]
    ) -> (passed: Bool, reason: String?) {
        var idx = expected.startIndex
        for kind in kinds {
            guard idx < expected.endIndex else { break }
            if kind == expected[idx] { idx = expected.index(after: idx) }
        }
        if idx < expected.endIndex {
            let matched = expected[..<idx].map(\.rawValue).joined(separator: ", ")
            let missing = expected[idx...].map(\.rawValue).joined(separator: ", ")
            let traceDesc = kinds.map(\.rawValue).joined(separator: ", ")
            return (false, "Matched: [\(matched)] — Missing: [\(missing)] — Trace: [\(traceDesc)]")
        }
        return (true, nil)
    }
}

// MARK: - In-memory MessageStore for the runner

// Mirrors InMemoryScenarioStore in ConversationRuntimeScenario.swift.
// Kept private to this file — the runner API exposes only Result types.
private final class ScenarioMessageStore: MessageStore, @unchecked Sendable {

    private let lock = NSLock()
    private var messages: [UUID: ChatMessage] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ChatMessage) async throws {
        let snapshot = upsertAndSnapshotHooks(message)
        for hook in snapshot {
            await hook.messageDidWrite(message, in: message.sessionID)
        }
    }

    func updateMessage(_ message: ChatMessage) async throws {
        let snapshot = upsertAndSnapshotHooks(message)
        for hook in snapshot {
            await hook.messageDidWrite(message, in: message.sessionID)
        }
    }

    func deleteMessage(_ messageID: UUID) async throws {
        removeMessage(id: messageID)
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messagesForSession(sessionID)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        removeMessagesForSession(sessionID)
    }

    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
        appendHook(hook)
    }

    // MARK: - Sync lock-helpers (avoid NSLock.unlock in async ctx)

    private func upsertAndSnapshotHooks(_ message: ChatMessage) -> [any MessageStorePostWriteHook] {
        lock.lock()
        defer { lock.unlock() }
        messages[message.id] = message
        return hooks
    }

    private func removeMessage(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        messages.removeValue(forKey: id)
    }

    private func messagesForSession(_ sessionID: UUID) -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func removeMessagesForSession(_ sessionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        messages = messages.filter { $0.value.sessionID != sessionID }
    }

    private func appendHook(_ hook: any MessageStorePostWriteHook) {
        lock.lock()
        defer { lock.unlock() }
        hooks.append(hook)
    }
}
#endif
