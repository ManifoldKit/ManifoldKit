@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``VideoGenerationRuntime`` — the video-side sibling to
/// ``ImageGenerationRuntime``. Drives a mock ``VideoGenerationBackend``
/// through the runtime, asserts events and persistence.
@MainActor
final class VideoGenerationRuntimeTests: XCTestCase {

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

    // MARK: - Mock video backend

    /// Controllable ``VideoGenerationBackend`` for driving the runtime.
    /// Each test configures the events the backend yields; the service wraps
    /// this stream and the runtime consumes from there.
    final class MockVideoBackend: VideoGenerationBackend, @unchecked Sendable {

        struct Plan: Sendable {
            var events: [VideoGenerationEvent] = []
            /// When non-nil the stream throws this after yielding all events.
            var trailingError: (any Error)?
            /// Thrown from `generate(...)` before a stream is returned.
            var submitError: (any Error)?
            /// Per-event delay — set to a large value to give cancellation
            /// time to interleave.
            var delayPerEventNs: UInt64 = 1_000_000  // 1ms
        }

        private struct State: Sendable {
            var plan = Plan()
            var cancelCalled = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var cancelCalled: Bool { lock.withLock { $0.cancelCalled } }

        func setPlan(_ plan: Plan) {
            lock.withLock { $0.plan = plan }
        }

        func generate(
            prompt: String,
            config: VideoGenerationConfig
        ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
            let plan = lock.withLock { $0.plan }

            if let error = plan.submitError {
                throw error
            }

            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> {
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    if let trailing = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailing)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func cancel() async {
            lock.withLock { $0.cancelCalled = true }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        backend: MockVideoBackend = MockVideoBackend(),
        modelIdentifier: String = "test-cloud-model"
    ) -> (
        runtime: VideoGenerationRuntime,
        store: RuntimeMessageStore,
        backend: MockVideoBackend
    ) {
        let store = RuntimeMessageStore()
        let service = VideoGenerationService(backend: backend)
        let runtime = VideoGenerationRuntime(
            service: service,
            messageStore: store,
            modelIdentifier: { modelIdentifier }
        )
        return (runtime, store, backend)
    }

    private static let config = VideoGenerationConfig(
        duration: 5,
        aspectRatio: VideoGenerationConfig.AspectRatio.landscape
    )

    enum TestError: Error { case deadlineElapsed }

    /// Drains ``VideoGenerationRuntime/events`` until `predicate` returns
    /// true or `deadline` elapses.
    private func collectEvents(
        from runtime: VideoGenerationRuntime,
        until predicate: @escaping @Sendable (VideoRuntimeEvent) -> Bool,
        deadline: Duration = .seconds(5)
    ) async throws -> [VideoRuntimeEvent] {
        var collected: [VideoRuntimeEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        let result = try await withThrowingTaskGroup(of: [VideoRuntimeEvent].self) { group in
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
        return result
    }

    private static let isTerminal: @Sendable (VideoRuntimeEvent) -> Bool = { event in
        switch event {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - Test 1: Happy path

    func test_generate_happyPath_persistsAndEmitsEvents() async throws {
        let videoURL = URL(fileURLWithPath: "/tmp/test-video-\(UUID().uuidString).mp4")
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .queued,
            .generating(fractionComplete: 0.3),
            .generating(fractionComplete: 0.8),
            .completed(videoURL)
        ]))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            prompt: "a mountain sunrise",
            config: Self.config,
            in: sessionID
        )

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        // Event sequence: started → progress(0.0) for .queued → progress(0.3)
        // → progress(0.8) → completed
        XCTAssertEqual(events.count, 5, "Expected started + 3× progress + completed; got \(events)")

        guard case .started(let startID, let prompt) = events[0] else {
            return XCTFail("Expected .started at index 0, got \(events[0])")
        }
        XCTAssertEqual(startID, messageID)
        XCTAssertEqual(prompt, "a mountain sunrise")

        guard case .progress(let pid0, let f0) = events[1] else {
            return XCTFail("Expected .progress at index 1 (from .queued), got \(events[1])")
        }
        XCTAssertEqual(pid0, messageID)
        XCTAssertEqual(f0, 0.0, accuracy: 0.001)

        guard case .progress(_, let f1) = events[2] else {
            return XCTFail("Expected .progress at index 2, got \(events[2])")
        }
        XCTAssertEqual(f1, 0.3, accuracy: 0.001)

        guard case .progress(_, let f2) = events[3] else {
            return XCTFail("Expected .progress at index 3, got \(events[3])")
        }
        XCTAssertEqual(f2, 0.8, accuracy: 0.001)

        guard case .completed(let cid, let payload) = events[4] else {
            return XCTFail("Expected .completed at index 4, got \(events[4])")
        }
        XCTAssertEqual(cid, messageID)
        XCTAssertEqual(payload.prompt, "a mountain sunrise")
        XCTAssertEqual(payload.videoURL, videoURL)
        XCTAssertEqual(payload.modelIdentifier, "test-cloud-model")
        XCTAssertEqual(payload.generationConfig.duration, 5)
        XCTAssertEqual(payload.generationConfig.aspectRatio, VideoGenerationConfig.AspectRatio.landscape)

        // Persistence: placeholder updated to carry .generatedVideo part.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, messageID)
        XCTAssertEqual(stored.first?.contentParts.count, 1)
        guard case .generatedVideo(let storedPayload) = stored.first?.contentParts.first else {
            return XCTFail("Expected stored part to be .generatedVideo")
        }
        XCTAssertEqual(storedPayload.videoURL, videoURL)
        XCTAssertEqual(storedPayload.modelIdentifier, "test-cloud-model")
    }

    // MARK: - Test 2: .queued maps to zero progress

    func test_generate_queuedEvent_emitsZeroProgress() async throws {
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .queued,
            .completed(URL(fileURLWithPath: "/tmp/out.mp4"))
        ]))

        let (runtime, _, _) = makeRuntime(backend: backend)

        _ = try await runtime.generate(prompt: "x", config: Self.config, in: UUID())

        // started → progress(0.0) from .queued → completed
        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        let progressFractions = events.compactMap { event -> Double? in
            if case .progress(_, let f) = event { return f }
            return nil
        }
        XCTAssertTrue(
            progressFractions.contains(0.0),
            "Expected progress(fractionComplete: 0.0) from the .queued backend event; got \(progressFractions)"
        )
    }

    // MARK: - Test 3: Backend submission failure

    func test_generate_submissionFailure_emitsFailedAndRethrows() async throws {
        struct CloudAuthError: Error {}
        let backend = MockVideoBackend()
        backend.setPlan(.init(submitError: CloudAuthError()))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        var messageID: UUID?
        do {
            messageID = try await runtime.generate(
                prompt: "a storm",
                config: Self.config,
                in: sessionID
            )
            XCTFail("Expected generate to rethrow the submission error")
        } catch is CloudAuthError {
            // expected — runtime emits .failed AND rethrows
        }

        // Drain events after the (synchronous-on-main-actor) generate call.
        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        // The placeholder was inserted before the submit attempt.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1, "Placeholder must be inserted even on submission failure")

        // The terminal event must be .failed carrying the message ID.
        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected terminal .failed event, got \(events.last as Any)")
        }
        if let mid = messageID {
            XCTAssertEqual(fid, mid)
        }
    }

    // MARK: - Test 4: Mid-stream backend error

    func test_generate_backendStreamError_emitsFailed() async throws {
        struct DownloadError: Error {}
        let backend = MockVideoBackend()
        backend.setPlan(.init(
            events: [.queued, .generating(fractionComplete: 0.5)],
            trailingError: DownloadError()
        ))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            prompt: "rain",
            config: Self.config,
            in: sessionID
        )

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected .failed terminal, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)

        // Placeholder remains with empty contentParts on failure.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(
            stored.first?.contentParts.isEmpty ?? false,
            "Expected placeholder contentParts empty on failure"
        )
    }

    // MARK: - Test 5: Cancellation

    func test_cancel_emitsCancelledAndLeavesPlaceholderEmpty() async throws {
        let backend = MockVideoBackend()
        backend.setPlan(.init(
            events: [
                .queued,
                .generating(fractionComplete: 0.1),
                .generating(fractionComplete: 0.2),
                .generating(fractionComplete: 0.3),
                .completed(URL(fileURLWithPath: "/tmp/never.mp4"))
            ],
            delayPerEventNs: 50_000_000  // 50ms per event — gives cancel time to interleave
        ))

        let (runtime, store, _) = makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            prompt: "snow",
            config: Self.config,
            in: sessionID
        )

        // Wait for at least one progress event before cancelling so the
        // consumer task is running.
        let preCancelTask = Task {
            var seen: [VideoRuntimeEvent] = []
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

        // Placeholder is NOT updated on cancel — empty contentParts.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(
            stored.first?.contentParts.isEmpty ?? false,
            "Expected placeholder contentParts empty on cancel; got \(stored.first?.contentParts as Any)"
        )
    }

    // MARK: - Test 6: cancel(messageID:) for unknown ID is a no-op

    func test_cancel_unknownMessageID_isNoOp() async {
        let (runtime, _, _) = makeRuntime()
        // Should not throw or crash for an ID with no in-flight generation.
        await runtime.cancel(messageID: UUID())
    }

    // MARK: - Test 7: Store update failure on completion

    func test_generate_storeUpdateError_emitsFailedNotCompleted() async throws {
        struct PersistenceFailure: Error {}
        let videoURL = URL(fileURLWithPath: "/tmp/ok.mp4")
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [.completed(videoURL)]))

        let (runtime, store, _) = makeRuntime(backend: backend)
        // Poison the store so `updateMessage` throws on the first call.
        store.updateError = PersistenceFailure()

        let sessionID = UUID()
        let messageID = try await runtime.generate(
            prompt: "a meadow",
            config: Self.config,
            in: sessionID
        )

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        // The runtime emits .failed, not .completed, when persistence fails.
        guard case .failed(let fid, _) = events.last else {
            return XCTFail("Expected .failed on store update error, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)
    }

    // MARK: - Test 8: modelIdentifier injected into payload

    func test_generate_modelIdentifier_appearsInPayload() async throws {
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .completed(URL(fileURLWithPath: "/tmp/v.mp4"))
        ]))

        let (runtime, _, _) = makeRuntime(backend: backend, modelIdentifier: "provider-x-v2")

        let _ = try await runtime.generate(
            prompt: "ocean",
            config: Self.config,
            in: UUID()
        )

        let events = try await collectEvents(from: runtime, until: Self.isTerminal)

        guard case .completed(_, let payload) = events.last else {
            return XCTFail("Expected .completed, got \(events.last as Any)")
        }
        XCTAssertEqual(payload.modelIdentifier, "provider-x-v2")
    }

    // MARK: - Test 9: VideoRuntimeEvent case discipline

    // Sentry: confirms VideoRuntimeEvent cases did not land on ConversationEvent.
    // ConversationEvent's case set is load-bearing for text-side adapters;
    // a video-side leak would silently add unreachable switch arms.
    func test_conversationEvent_caseCount_unchangedByVideoRuntime() {
        let samples: [ConversationEvent] = [
            .messageInserted(ChatMessage(role: .user, content: "", sessionID: UUID())),
            .messageRemoved(messageID: UUID()),
            .messageUpdated(ChatMessage(role: .user, content: "", sessionID: UUID())),
            .sessionBranched(newSessionID: UUID(), copiedCount: 0),
            .streamStarted(messageID: UUID()),
            .tokenEmitted(messageID: UUID(), delta: ""),
            .tokenUsageRecorded(messageID: UUID(), promptTokens: 0, completionTokens: 0),
            .thinkingStarted(messageID: UUID()),
            .thinkingUpdated(messageID: UUID(), partialText: ""),
            .thinkingFinalized(messageID: UUID(), text: "", signature: nil),
            .loopDetected(messageID: UUID()),
            .streamFinished(messageID: UUID(), reason: .stop),
            .errorRaised(.cancelled),
            .sessionTouchFailed(sessionID: UUID()),
            .beforeContextAssembly(prompt: nil, request: PromptContextRequest(sessionID: UUID(), messageCount: 0, userInput: nil)),
            .historyShaped(sessionID: UUID(), diagnostics: []),
            .contextAssembled(slots: []),
            .afterGeneration(messageID: UUID(), finalText: ""),
            .compressionTriggered(removed: [], reason: .manual),
            .historyCompressed(sessionID: UUID(), insertedRecords: []),
            .toolCallRequested(ToolCall(id: "", toolName: "", arguments: "")),
            .toolCallApproved(""),
            .toolCallCompleted("", ToolResult(callId: "", content: "")),
            .agentHandoff(from: nil, to: UUID()),
            .skillInvoked(name: "", sessionID: UUID()),
            .hookFired(event: "", sessionID: UUID())
        ]
        // Exhaustive switch is the actual gate — adding a video case here
        // would fail to compile, which is the point.
        for event in samples {
            switch event {
            case .messageInserted, .messageRemoved, .messageUpdated, .sessionBranched,
                 .streamStarted, .tokenEmitted, .tokenUsageRecorded,
                 .thinkingStarted, .thinkingUpdated, .thinkingFinalized,
                 .loopDetected, .streamFinished, .errorRaised, .sessionTouchFailed,
                 .beforeContextAssembly, .historyShaped, .contextAssembled, .afterGeneration,
                 .compressionTriggered, .historyCompressed, .toolCallRequested, .toolCallApproved,
                 .toolCallCompleted, .agentHandoff, .skillInvoked, .hookFired:
                continue
            }
        }
        XCTAssertEqual(samples.count, 26,
            "ConversationEvent case count drifted — video-side cases may have leaked in")
    }
}
