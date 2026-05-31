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

        public enum RunModeKind: Sendable { case scripted, live }
    }

    /// Runs `scenario` in `mode` and returns the result.
    ///
    /// Does not call `XCTFail` — callers (typically XCTest methods) should
    /// call ``assert(result:file:line:)`` to surface failures.
    public static func run(
        _ scenario: RuntimeScenario,
        mode: RunMode = .scripted
    ) async throws -> Result {
        let backend: any InferenceBackend
        let modeKind: Result.RunModeKind

        switch mode {
        case .scripted:
            let scripted = ScriptedGenerationBackend(turns: scenario.scriptedTurns)
            // ScriptedGenerationBackend defaults isModelLoaded = true so no
            // extra step is needed; mark it explicit for clarity.
            scripted.isModelLoaded = true
            backend = scripted
            modeKind = .scripted
        case .live(let liveBackend):
            backend = liveBackend
            modeKind = .live
        }

        let store = ScenarioMessageStore()
        let inferenceService = InferenceService(backend: backend, name: "ScenarioRunner-\(scenario.id)")
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inferenceService,
            preTurnCompressionPolicy: scenario.preTurnCompressionPolicy
        )

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let sessionID = UUID()
        for message in scenario.userMessages {
            let input = TurnInput(sessionID: sessionID, kind: .send(text: message))
            let handle = try await runtime.processTurnWithOutcome(input)
            _ = await handle?.outcome
        }

        drainTask.cancel()
        await drainTask.value

        let trace = await ConversationEventTrace(recorder: recorder)
        let (passed, reason) = checkSubsequence(trace.kinds, against: scenario.expectedSubsequence)

        return Result(
            scenario: scenario,
            mode: modeKind,
            trace: trace,
            subsequencePassed: passed,
            subsequenceFailureReason: reason
        )
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
    private var messages: [UUID: ChatMessageRecord] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ChatMessageRecord) async throws {
        let snapshot = upsertAndSnapshotHooks(message)
        for hook in snapshot {
            await hook.messageDidWrite(message, in: message.sessionID)
        }
    }

    func updateMessage(_ message: ChatMessageRecord) async throws {
        let snapshot = upsertAndSnapshotHooks(message)
        for hook in snapshot {
            await hook.messageDidWrite(message, in: message.sessionID)
        }
    }

    func deleteMessage(_ messageID: UUID) async throws {
        removeMessage(id: messageID)
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        messagesForSession(sessionID)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        removeMessagesForSession(sessionID)
    }

    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
        appendHook(hook)
    }

    // MARK: - Sync lock-helpers (avoid NSLock.unlock in async ctx)

    private func upsertAndSnapshotHooks(_ message: ChatMessageRecord) -> [any MessageStorePostWriteHook] {
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

    private func messagesForSession(_ sessionID: UUID) -> [ChatMessageRecord] {
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
