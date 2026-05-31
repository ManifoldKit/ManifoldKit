@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - ScriptedBackendRuntimeTests

/// Integration tests wiring ``ScriptedGenerationBackend`` through
/// ``ConversationRuntime``, ``ConversationEventRecorder``, and
/// ``XCTAssertEventSubsequence``.
///
/// Prerequisites: P0 (`ConversationEventRecorder`) and P1
/// (`ConversationEventKind`, `XCTAssertEventSubsequence`) must be merged.
@MainActor
final class ScriptedBackendRuntimeTests: XCTestCase {

    // MARK: - In-memory MessageStore

    private final class ScriptedTestMessageStore: MessageStore, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessageRecord) async throws {
            let snapshot = upsert(message)
            for hook in snapshot {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard lock.withLock({ messages[message.id] != nil }) else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            let snapshot = upsert(message)
            for hook in snapshot {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            lock.withLock { messages.removeValue(forKey: messageID) }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            lock.withLock {
                messages.values
                    .filter { $0.sessionID == sessionID }
                    .sorted { $0.timestamp < $1.timestamp }
            }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            lock.withLock {
                messages = messages.filter { $0.value.sessionID != sessionID }
            }
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
            lock.withLock { hooks.append(hook) }
        }

        private func upsert(_ message: ChatMessageRecord) -> [any MessageStorePostWriteHook] {
            lock.withLock {
                messages[message.id] = message
                return hooks
            }
        }
    }

    // MARK: - Fixture factory

    private func makeRuntime(
        backend: ScriptedGenerationBackend
    ) -> (runtime: ConversationRuntime, backend: ScriptedGenerationBackend) {
        let inference = InferenceService(backend: backend, name: "Scripted")
        let store = ScriptedTestMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)
        return (runtime, backend)
    }

    // MARK: - Drain helper

    /// Drains the primary `runtime.events` stream until `streamFinished` (or
    /// `errorRaised`) arrives, or the deadline elapses.
    private func drainUntilTerminal(
        _ runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) -> Task<Void, Never> {
        Task { [weak runtime] in
            guard let runtime else { return }
            for await event in runtime.events {
                if case .streamFinished = event { break }
                if case .errorRaised = event { break }
            }
        }
    }

    // MARK: - Tests

    /// `.kvCacheReuse` is advisory metadata that the runtime passes through
    /// as `.ignore`. The turn must still complete normally — `streamFinished`
    /// (not `errorRaised`) must appear in the trace.
    func test_kvCacheReuse_completesNormally() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .kvCacheReuse(reuseCount: 256, then: ["Hello", " world"])
        ])
        let (runtime, _) = makeRuntime(backend: backend)

        let primaryTask = drainUntilTerminal(runtime)
        defer { primaryTask.cancel() }

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let turn = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "test kv-cache"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        _ = await turn?.outcome

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace

        // The runtime ignores .kvCacheReuse at the ConversationEvent level but
        // must complete the turn successfully — streamFinished (not errorRaised)
        // must appear.
        XCTAssertEventSubsequence(trace, contains: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ], "turn with kvCacheReuse must complete normally")

        // errorRaised must not appear — kvCacheReuse is advisory.
        let hasError = trace.contains { $0.kind == .errorRaised }
        XCTAssertFalse(hasError, "kvCacheReuse must not cause errorRaised")
    }

    /// `.diagnosticThrottle` is advisory and must not abort generation.
    /// The turn must complete with `streamFinished`, not `errorRaised`.
    func test_diagnosticThrottle_doesNotAbortGeneration() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .throttle(reason: "rate-limit", then: ["ok"])
        ])
        let (runtime, _) = makeRuntime(backend: backend)

        let primaryTask = drainUntilTerminal(runtime)
        defer { primaryTask.cancel() }

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let turn = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "throttle test"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        _ = await turn?.outcome

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace

        XCTAssertEventSubsequence(trace, contains: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ], "throttle is advisory — generation must complete normally")

        let hasError = trace.contains { $0.kind == .errorRaised }
        XCTAssertFalse(hasError, "diagnosticThrottle must not cause errorRaised")
    }

    /// A mid-stream error surfaces as `errorRaised` in the trace. The
    /// token emitted before the throw must also appear so the test verifies
    /// the ordering of the partial-output + error path.
    func test_midStreamError_surfacesAsErrorRaised() async throws {
        let testError = NSError(domain: "test.mid-stream", code: 42)
        let backend = ScriptedGenerationBackend(turns: [
            .failMidStream(testError, afterTokens: 1, tokens: ["hi", "bye"])
        ])
        let (runtime, _) = makeRuntime(backend: backend)

        // Drain primary stream — errorRaised terminates the loop.
        let primaryTask = drainUntilTerminal(runtime)
        defer { primaryTask.cancel() }

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let turn = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "error test"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        _ = await turn?.outcome

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace

        XCTAssertEventSubsequence(trace, contains: [
            .tokenEmitted,
            .errorRaised,
        ], "partial token then errorRaised must appear after mid-stream throw")
    }

    /// A two-turn script drives two independent `processTurnWithOutcome` calls.
    /// The combined trace must contain the per-turn landmarks in order.
    func test_multiTurnScript_eachTurnTracedIndependently() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .tokens(["A"]),
            .kvCacheReuse(reuseCount: 64, then: ["B"]),
        ])
        let (runtime, _) = makeRuntime(backend: backend)

        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        let recorder = ConversationEventRecorder()
        let drainTask = await recorder.start(on: runtime)

        let sessionID = UUID()

        let turn1 = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "first"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        _ = await turn1?.outcome

        let turn2 = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "second"),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
        _ = await turn2?.outcome

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace

        // Both turns must have completed with their own streamStarted / tokenEmitted /
        // streamFinished lifecycle. The six-event subsequence below is the minimal
        // proof that two independent generation rounds ran.
        XCTAssertEventSubsequence(trace, contains: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ], "two-turn scripted session must produce two complete generation lifecycles")
    }
}
