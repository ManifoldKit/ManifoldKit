@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - ConversationEventTapTests

/// Integration coverage for the multicast event tap on ``ConversationRuntime``.
///
/// A tap installed via ``ConversationRuntime/addEventTap(bufferingPolicy:)``
/// receives the full turn transcript independently of the primary ``events``
/// consumer.
@MainActor
final class ConversationEventTapTests: XCTestCase {

    // MARK: - In-memory MessageStore

    private final class TapMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
    }

    // MARK: - Drain helper

    /// Drains `stream` until a ``ConversationEvent/streamFinished`` event arrives
    /// or the `deadline` elapses. Returns the full captured transcript.
    private func drain(
        _ stream: AsyncStream<ConversationEvent>,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        let task = Task {
            var collected: [ConversationEvent] = []
            for await event in stream {
                collected.append(event)
                if case .streamFinished = event { break }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw NSError(domain: "ConversationEventTapTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "deadline elapsed waiting for streamFinished"])
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: - Fixture factory

    private func makeRuntime(
        tokens: [String] = ["Hello", " world"]
    ) -> (runtime: ConversationRuntime, mock: MockInferenceBackend) {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = TapMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)
        return (runtime, mock)
    }

    private func sendTurn(
        on runtime: ConversationRuntime,
        text: String = "hi"
    ) async throws -> ConversationTurnHandle? {
        let sessionID = UUID()
        return try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: text),
            config: TurnConfig(streamingBatchCharacterLimit: 1)
        ))
    }

    // MARK: - Tests

    /// A tap installed before a turn sees `.streamStarted`, token deltas, and
    /// `.streamFinished`. The primary `events` stream is not starved.
    func test_tap_seesFullTurnTrace() async throws {
        let (runtime, _) = makeRuntime(tokens: ["Hel", "lo", " world"])

        let tapStream = runtime.addEventTap()
        let tapDrainTask = Task { try await self.drain(tapStream) }
        let primaryDrainTask = Task { try await self.drain(runtime.events) }

        let turn = try await sendTurn(on: runtime)
        // Bound the outcome wait so a generation-loop stall surfaces as a
        // deterministic test failure instead of a 240 s CI watchdog kill.
        let outcome = try await withTimeout(.seconds(10)) {
            await turn?.outcome
        }
        XCTAssertEqual(outcome?.reason, .stop)
        let messageID = try XCTUnwrap(outcome?.assistantMessageID)

        let tapTrace = try await tapDrainTask.value
        let primaryTrace = try await primaryDrainTask.value

        // Tap must contain the structural subsequence: started < tokens < finished.
        let startIdx = tapTrace.firstIndex {
            if case let .streamStarted(id) = $0 { return id == messageID }
            return false
        }
        let finishIdx = tapTrace.firstIndex {
            if case let .streamFinished(id, _) = $0 { return id == messageID }
            return false
        }
        let tokenIdxs = tapTrace.indices.filter {
            if case let .tokenEmitted(id, _) = tapTrace[$0] { return id == messageID }
            return false
        }

        let started = try XCTUnwrap(startIdx, "tap must observe streamStarted")
        let finished = try XCTUnwrap(finishIdx, "tap must observe streamFinished")
        XCTAssertFalse(tokenIdxs.isEmpty, "tap must observe at least one tokenEmitted")
        XCTAssertLessThan(started, tokenIdxs.first!, "streamStarted must precede first tokenEmitted in tap")
        XCTAssertLessThan(tokenIdxs.last!, finished, "last tokenEmitted must precede streamFinished in tap")

        // Reassembled text must match the scripted output.
        let tapText = tapTrace.compactMap { event -> String? in
            guard case let .tokenEmitted(id, delta) = event, id == messageID else { return nil }
            return delta
        }.joined()
        XCTAssertEqual(tapText, "Hello world", "tap must reassemble the full streamed text")

        // Primary stream must not be starved.
        let primarySawStart = primaryTrace.contains {
            if case let .streamStarted(id) = $0 { return id == messageID }
            return false
        }
        let primarySawFinish = primaryTrace.contains {
            if case let .streamFinished(id, _) = $0 { return id == messageID }
            return false
        }
        XCTAssertTrue(primarySawStart, "primary events stream must observe streamStarted")
        XCTAssertTrue(primarySawFinish, "primary events stream must observe streamFinished")
    }

    /// Two taps installed before a turn each independently receive every event.
    func test_multipleTaps_eachReceiveAllEvents() async throws {
        let (runtime, _) = makeRuntime(tokens: ["tok1", "tok2"])

        let tap1 = runtime.addEventTap()
        let tap2 = runtime.addEventTap()

        let drainTask1 = Task { try await self.drain(tap1) }
        let drainTask2 = Task { try await self.drain(tap2) }
        // Keep the primary stream drained so it doesn't interfere.
        let primaryTask = Task { try await self.drain(runtime.events) }

        let turn = try await sendTurn(on: runtime)
        // Bound the outcome wait so a generation-loop stall surfaces as a
        // deterministic test failure instead of a 240 s CI watchdog kill.
        let outcome = try await withTimeout(.seconds(10)) {
            await turn?.outcome
        }
        let messageID = try XCTUnwrap(outcome?.assistantMessageID)

        let trace1 = try await drainTask1.value
        let trace2 = try await drainTask2.value
        primaryTask.cancel()

        // Both taps must see identical token content.
        func tokens(in trace: [ConversationEvent], id: UUID) -> [String] {
            trace.compactMap { event -> String? in
                guard case let .tokenEmitted(eID, delta) = event, eID == id else { return nil }
                return delta
            }
        }

        let tokens1 = tokens(in: trace1, id: messageID)
        let tokens2 = tokens(in: trace2, id: messageID)
        XCTAssertFalse(tokens1.isEmpty, "tap1 must capture tokens")
        XCTAssertEqual(tokens1, tokens2, "both taps must see the same token sequence")

        // Both taps must see streamFinished.
        XCTAssertTrue(trace1.contains { if case .streamFinished = $0 { return true }; return false },
                      "tap1 must observe streamFinished")
        XCTAssertTrue(trace2.contains { if case .streamFinished = $0 { return true }; return false },
                      "tap2 must observe streamFinished")
    }

    /// A tap installed after the turn has already started still receives the
    /// remaining events for that turn (tail observation).
    func test_tap_installedAfterTurnStart_seesRemainingEvents() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        // Use a gate so we can insert the tap between tokens.
        let gate = TokenEmissionGate()
        mock.tokenEmissionGate = gate
        mock.tokensToYield = ["early", "late"]
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = TapMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)

        // Drain the primary stream to prevent it from blocking broadcast.
        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        // Start the turn, release only the first token.
        let sessionID = UUID()
        let turnTask = Task {
            try await runtime.processTurnWithOutcome(TurnInput(
                sessionID: sessionID,
                kind: .send(text: "hello"),
                config: TurnConfig(streamingBatchCharacterLimit: 1)
            ))
        }

        // Release first token so generation is clearly underway.
        await gate.advance()
        // Small yield to let the event propagate.
        await Task.yield()

        // Install tap NOW (mid-turn).
        let lateStream = runtime.addEventTap()
        let lateTask = Task { try await self.drain(lateStream) }

        // Release remaining token + allow stream to finish.
        await gate.advance()
        await gate.release()

        let turn = try await turnTask.value
        // Bound the outcome wait so a generation-loop stall surfaces as a
        // deterministic test failure instead of a 240 s CI watchdog kill.
        _ = try await withTimeout(.seconds(10)) { await turn?.outcome }

        let lateTrace = try await lateTask.value

        // The late tap must have seen at least the streamFinished event.
        let sawFinish = lateTrace.contains { if case .streamFinished = $0 { return true }; return false }
        XCTAssertTrue(sawFinish, "late-installed tap must see at least streamFinished")
    }

    /// Cancelling the tap stream (allowing it to go out of scope / task cancel)
    /// removes it from the registry so it does not leak.
    func test_tap_deregistersOnCancel() async throws {
        let (runtime, _) = makeRuntime()

        // Drain the primary stream.
        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        let tapStream = runtime.addEventTap()

        // Install a drain task that we will cancel immediately.
        let drainTask = Task {
            for await _ in tapStream {}
        }
        drainTask.cancel()

        // Allow the cancellation to propagate through the onTermination handler.
        for _ in 0..<10 { await Task.yield() }

        // Drive a turn — if the cancelled tap was leaked the registry would hold
        // a dangling continuation that would receive broadcasts but never be read.
        // We can only assert the tap task itself is no longer live; the registry
        // deregistration is an implementation detail, so the observable contract
        // is that the cancelled drain does not receive further events.
        let turn = try await sendTurn(on: runtime)
        // Bound the outcome wait so a generation-loop stall surfaces as a
        // deterministic test failure instead of a 240 s CI watchdog kill.
        let outcome = try await withTimeout(.seconds(10)) {
            await turn?.outcome
        }
        XCTAssertEqual(outcome?.reason, .stop, "turn should complete normally after tap cancel")
        // The cancelled task completes without blocking.
        _ = await drainTask.value
    }

    /// After the runtime is deallocated (turn loop exits), all installed tap
    /// streams finish normally.
    func test_tap_finishesWhenRuntimeTeardown() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["one"]

        var runtime: ConversationRuntime? = ConversationRuntime(
            messageStore: TapMessageStore(),
            inferenceService: InferenceService(backend: mock, name: "Mock")
        )

        let tapStream = runtime!.addEventTap()

        // Collect events from the tap until it finishes.
        let finishFlag = FinishFlag()
        let drainTask = Task {
            for await _ in tapStream {}
            await finishFlag.signal()
        }

        // Drain primary stream to avoid blocking broadcasts.
        let primaryTask = Task { [weak runtime] in
            guard let runtime else { return }
            for await _ in runtime.events {}
        }
        defer { primaryTask.cancel() }

        // Run one turn.
        let turn = try await runtime!.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "bye"),
            config: TurnConfig()
        ))
        // Bound the outcome wait so a generation-loop stall surfaces as a
        // deterministic test failure instead of a 240 s CI watchdog kill.
        _ = try await withTimeout(.seconds(10)) { await turn?.outcome }

        // Release the runtime — deinit fires and must finish all taps.
        runtime = nil

        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await finishFlag.wait(); return true }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw NSError(domain: "ConversationEventTapTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "tap did not finish after runtime teardown"])
            }
            let result = try await group.next()
            group.cancelAll()
            return result ?? false
        }

        XCTAssertTrue(finished, "tap stream must finish when runtime deallocates")
        _ = drainTask
    }

    // MARK: - Private helpers

    private actor FinishFlag {
        private var isSet = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !isSet else { return }
            isSet = true
            let pending = waiters
            waiters.removeAll()
            for w in pending { w.resume() }
        }

        func wait() async {
            if isSet { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
