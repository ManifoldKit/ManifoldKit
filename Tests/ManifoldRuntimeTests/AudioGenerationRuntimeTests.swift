@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``AudioGenerationRuntime`` — the audio-side sibling to
/// ``ImageGenerationRuntime`` / ``VideoGenerationRuntime``. Drives a mock
/// ``AudioGenerationBackend`` through the service + runtime and asserts events
/// and persistence into an in-memory ``MessageStore``.
@MainActor
final class AudioGenerationRuntimeTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        var updateError: (any Error)?

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }

        func updateMessage(_ message: ChatMessage) async throws {
            if let error = updateError {
                updateError = nil
                throw error
            }
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

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Mock audio backend

    /// Controllable ``AudioGenerationBackend`` for driving the runtime. The
    /// `generate` entrypoint is synchronous-throw (a local synth), matching the
    /// real backend's shape. State is guarded by `OSAllocatedUnfairLock` so the
    /// off-actor producer task can update flags without a race.
    final class MockAudioBackend: AudioGenerationBackend, @unchecked Sendable {

        struct Plan: Sendable {
            var events: [AudioGenerationEvent] = []
            /// When non-nil the stream throws this after yielding all events.
            var trailingError: (any Error)?
            /// Thrown from `generate(config:)` before a stream is returned.
            var submitError: (any Error)?
            /// Per-event delay — set large to give cancellation time to interleave.
            var delayPerEventNs: UInt64 = 1_000_000  // 1ms
        }

        private struct State: Sendable {
            var plan = Plan()
            var isGenerating = false
            var stopCalled = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var stopCalled: Bool { lock.withLock { $0.stopCalled } }
        var isGenerating: Bool { lock.withLock { $0.isGenerating } }

        func setPlan(_ plan: Plan) {
            lock.withLock { $0.plan = plan }
        }

        func generate(
            config: SpeechGenerationConfig
        ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error> {
            let plan = lock.withLock { state -> Plan in
                state.isGenerating = true
                return state.plan
            }

            if let error = plan.submitError {
                lock.withLock { $0.isGenerating = false }
                throw error
            }

            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> { [lock] in
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    lock.withLock { $0.isGenerating = false }
                    if let trailing = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailing)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() {
            lock.withLock {
                $0.stopCalled = true
                $0.isGenerating = false
            }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        backend: MockAudioBackend = MockAudioBackend(),
        modelIdentifier: String = "test-tts-model"
    ) -> (
        runtime: AudioGenerationRuntime,
        store: RuntimeMessageStore,
        backend: MockAudioBackend
    ) {
        let store = RuntimeMessageStore()
        let service = AudioGenerationService(backend: backend)
        let runtime = AudioGenerationRuntime(
            service: service,
            messageStore: store,
            modelIdentifier: { modelIdentifier }
        )
        return (runtime, store, backend)
    }

    private static let config = SpeechGenerationConfig(text: "hello world")

    enum TestError: Error { case deadlineElapsed }

    /// Drains ``AudioGenerationRuntime/events`` until `predicate` returns true
    /// or `deadline` elapses.
    private func collectEvents(
        from runtime: AudioGenerationRuntime,
        until predicate: @escaping @Sendable (AudioRuntimeEvent) -> Bool,
        deadline: Duration = .seconds(5)
    ) async throws -> [AudioRuntimeEvent] {
        let task = Task {
            var collected: [AudioRuntimeEvent] = []
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [AudioRuntimeEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestError.deadlineElapsed
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    private static let isTerminal: @Sendable (AudioRuntimeEvent) -> Bool = { event in
        switch event {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - Test 1: Happy path persists .generatedMedia/audio

    func test_generate_happyPath_persistsAudioAndEmitsEvents() async throws {
        let audioURL = URL(fileURLWithPath: "/tmp/tts-\(UUID().uuidString).caf")
        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 3),
            .progress(step: 2, total: 3),
            .completed(audioURL)
        ]))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            config: SpeechGenerationConfig(text: "a spoken sentence"),
            in: sessionID
        )

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        // started → progress → progress → completed
        XCTAssertEqual(events.count, 4, "Expected started + 2× progress + completed; got \(events)")

        guard case .started(let startID, let prompt) = events[0] else {
            return XCTFail("Expected .started at index 0, got \(events[0])")
        }
        XCTAssertEqual(startID, messageID)
        XCTAssertEqual(prompt, "a spoken sentence")

        guard case .progress(let pid, let step, let total) = events[1] else {
            return XCTFail("Expected .progress at index 1, got \(events[1])")
        }
        XCTAssertEqual(pid, messageID)
        XCTAssertEqual(step, 1)
        XCTAssertEqual(total, 3)

        guard case .completed(let cid, let payload) = events[3] else {
            return XCTFail("Expected .completed at index 3, got \(events[3])")
        }
        XCTAssertEqual(cid, messageID)
        XCTAssertEqual(payload.kind, .audio)
        XCTAssertEqual(payload.prompt, "a spoken sentence")
        XCTAssertEqual(payload.url, audioURL)
        XCTAssertEqual(payload.modelIdentifier, "test-tts-model")
        XCTAssertEqual(payload.format, "audio/x-caf")

        // Persistence: placeholder updated to carry a .generatedMedia audio part.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, messageID)
        XCTAssertEqual(stored.first?.contentParts.count, 1)
        guard case .generatedMedia(let storedPayload) = stored.first?.contentParts.first else {
            return XCTFail("Expected stored part to be .generatedMedia")
        }
        XCTAssertEqual(storedPayload.kind, .audio)
        XCTAssertEqual(storedPayload.url, audioURL)
        XCTAssertEqual(storedPayload.modelIdentifier, "test-tts-model")
    }

    // MARK: - Test 2: total==0 falls back to step

    func test_generate_zeroTotal_fallsBackToStep() async throws {
        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [
            .progress(step: 5, total: 0),
            .completed(URL(fileURLWithPath: "/tmp/o.caf"))
        ]))

        let (runtime, _, _) = makeRuntime(backend: backend)
        _ = try await runtime.generate(config: Self.config, in: UUID())

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        let progress = events.compactMap { event -> (Int, Int)? in
            if case .progress(_, let s, let t) = event { return (s, t) }
            return nil
        }
        XCTAssertEqual(progress.first?.0, 5)
        XCTAssertEqual(progress.first?.1, 5, "total==0 should fall back to step")
    }

    // MARK: - Test 3: backend submission failure emits .failed

    func test_generate_submissionFailure_emitsFailed() async throws {
        struct SynthError: Error {}
        let backend = MockAudioBackend()
        backend.setPlan(.init(submitError: SynthError()))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        // The runtime's `generate` does NOT rethrow a backend submit error
        // (the synchronous-throw service path surfaces it through the stream);
        // it inserts the placeholder and emits .failed on the event stream.
        let messageID = try await runtime.generate(config: Self.config, in: sessionID)

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1, "Placeholder must be inserted even on submission failure")

        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected terminal .failed event, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)
    }

    // MARK: - Test 4: mid-stream error emits .failed, placeholder stays empty

    func test_generate_streamError_emitsFailedAndLeavesPlaceholderEmpty() async throws {
        struct RenderError: Error {}
        let backend = MockAudioBackend()
        backend.setPlan(.init(
            events: [.progress(step: 1, total: 4)],
            trailingError: RenderError()
        ))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(config: Self.config, in: sessionID)
        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected .failed terminal, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)

        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(
            stored.first?.contentParts.isEmpty ?? false,
            "Expected placeholder contentParts empty on failure"
        )
    }

    // MARK: - Test 5: cancellation tears down and leaves placeholder empty

    func test_cancel_emitsCancelledAndLeavesPlaceholderEmpty() async throws {
        let backend = MockAudioBackend()
        backend.setPlan(.init(
            events: [
                .progress(step: 1, total: 5),
                .progress(step: 2, total: 5),
                .progress(step: 3, total: 5),
                .completed(URL(fileURLWithPath: "/tmp/never.caf"))
            ],
            delayPerEventNs: 50_000_000  // 50ms per event — lets cancel interleave
        ))

        let (runtime, store, mockBackend) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(config: Self.config, in: sessionID)

        // Wait for the first progress event so the consumer task is running.
        let preCancelTask = Task {
            var seen: [AudioRuntimeEvent] = []
            for await event in runtime.events {
                seen.append(event)
                if case .progress = event { break }
            }
            return seen
        }
        _ = await preCancelTask.value

        await runtime.cancel(messageID: messageID)

        let terminal = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .cancelled(let cid) = terminal.last else {
            return XCTFail("Expected .cancelled terminal, got \(terminal.last as Any)")
        }
        XCTAssertEqual(cid, messageID)

        // Backend was told to stop via the service's cancellation hook.
        XCTAssertTrue(mockBackend.stopCalled, "Expected backend.stopGeneration() on cancel")

        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(
            stored.first?.contentParts.isEmpty ?? false,
            "Expected placeholder contentParts empty on cancel; got \(stored.first?.contentParts as Any)"
        )
    }

    // MARK: - Test 6: cancel for unknown ID is a no-op

    func test_cancel_unknownMessageID_isNoOp() async {
        let (runtime, _, _) = makeRuntime()
        await runtime.cancel(messageID: UUID())
    }

    // MARK: - Test 7: store update failure on completion emits .failed

    func test_generate_storeUpdateError_emitsFailedNotCompleted() async throws {
        struct PersistenceFailure: Error {}
        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [.completed(URL(fileURLWithPath: "/tmp/ok.caf"))]))

        let (runtime, store, _) = makeRuntime(backend: backend)
        store.updateError = PersistenceFailure()

        let sessionID = UUID()
        let messageID = try await runtime.generate(config: Self.config, in: sessionID)
        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected .failed on store update error, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)
    }

    // MARK: - Test 8: modelIdentifier injected into payload

    func test_generate_modelIdentifier_appearsInPayload() async throws {
        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [.completed(URL(fileURLWithPath: "/tmp/v.caf"))]))

        let (runtime, _, _) = makeRuntime(backend: backend, modelIdentifier: "apple-tts-v2")

        _ = try await runtime.generate(config: Self.config, in: UUID())
        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .completed(_, let payload) = events.last else {
            return XCTFail("Expected .completed, got \(events.last as Any)")
        }
        XCTAssertEqual(payload.modelIdentifier, "apple-tts-v2")
    }
}
