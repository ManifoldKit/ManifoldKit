@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``ChatViewModel`` audio-generation (TTS) entry surface — runtime
/// install, command forwarding, and event-to-progress mapping. Sibling to
/// ``ChatViewModelImageGenerationTests``. The shape differs from the image/video
/// siblings only where the shipped runtime differs: `generateSpeech` takes the
/// config alone (the text lives in ``SpeechGenerationConfig``), and the
/// completion event carries a ``GeneratedMediaPayload`` directly.
@MainActor
final class ChatViewModelAudioGenerationTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class TestMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }
        func updateMessage(_ message: ChatMessage) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            messages.removeValue(forKey: messageID)
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Mock backend (driven by a configurable plan)

    final class MockAudioBackend: AudioGenerationBackend, @unchecked Sendable {
        struct Plan: Sendable {
            var events: [AudioGenerationEvent] = []
            var trailingError: (any Error)?
            var delayPerEventNs: UInt64 = 1_000_000
        }

        private struct State: Sendable {
            var isGenerating = false
            var plan = Plan()
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var isGenerating: Bool { state.withLock { $0.isGenerating } }

        func setPlan(_ plan: Plan) { state.withLock { $0.plan = plan } }

        func generate(
            config: SpeechGenerationConfig
        ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error> {
            let plan: Plan = state.withLock { snap in
                snap.isGenerating = true
                return snap.plan
            }
            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> { [self] in
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    if let trailingError = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailingError)
                    } else {
                        continuation.finish()
                    }
                    self.state.withLock { $0.isGenerating = false }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() { state.withLock { $0.isGenerating = false } }
    }

    // MARK: - Builders

    private func makeRuntime(backend: MockAudioBackend) -> (AudioGenerationRuntime, TestMessageStore) {
        let service = AudioGenerationService(backend: backend)
        let store = TestMessageStore()
        let runtime = AudioGenerationRuntime(service: service, messageStore: store)
        return (runtime, store)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelAudioGenerationTests-\(UUID().uuidString)")!
        )
    }

    /// Spin until `predicate(vm.audioGenerationProgress[messageID])` becomes
    /// `true`, or fail after `timeout`. The progress dict is updated from a
    /// detached `@MainActor` task so we yield in a tight loop rather than
    /// using a one-shot expectation — events arrive in batches.
    private func awaitProgress(
        _ vm: ChatViewModel,
        for messageID: UUID,
        until predicate: (AudioGenerationProgress) -> Bool,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let progress = vm.audioGenerationProgress[messageID], predicate(progress) {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for progress predicate on \(messageID)", file: file, line: line)
    }

    // MARK: - Test 1: not configured

    func test_generateSpeech_withoutConfiguredRuntime_throwsNotConfigured() async {
        let vm = makeViewModel()
        vm.activeSession = ChatSession(title: "Test")
        do {
            _ = try await vm.generateSpeech(config: SpeechGenerationConfig(text: "hello"))
            XCTFail("Expected throw")
        } catch let error as ChatViewModelAudioError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Test 2: no active conversation

    func test_generateSpeech_withoutActiveSession_throwsNoActiveConversation() async throws {
        let backend = MockAudioBackend()
        let (runtime, _) = makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(audioRuntime: runtime)
        // No session set — activeSessionID is nil.
        XCTAssertNil(vm.activeSessionID)
        do {
            _ = try await vm.generateSpeech(config: SpeechGenerationConfig(text: "hello"))
            XCTFail("Expected throw")
        } catch let error as ChatViewModelAudioError {
            XCTAssertEqual(error, .noActiveConversation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Test 3: happy path — placeholder inserted, ID returned, completion sets media

    func test_generateSpeech_happyPath_insertsPlaceholderAndSetsGeneratedMedia() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("avm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let audioURL = outDir.appendingPathComponent("out.caf")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: audioURL)

        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 4),
            .progress(step: 2, total: 4),
            .progress(step: 3, total: 4),
            .progress(step: 4, total: 4),
            .completed(audioURL)
        ]))

        let (runtime, _) = makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(audioRuntime: runtime)
        vm.activeSession = ChatSession(title: "Audio Test")

        let messageID = try await vm.generateSpeech(
            config: SpeechGenerationConfig(text: "read this aloud", outputDirectory: outDir)
        )

        // A placeholder message must be appended for the returned ID.
        await awaitProgress(vm, for: messageID) { p in
            p.prompt == "read this aloud" && !p.isComplete
        }
        XCTAssertTrue(
            vm.messages.contains(where: { $0.id == messageID }),
            "A placeholder message should be inserted for the returned ID"
        )

        // Wait for terminal completion.
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }

        let final = vm.audioGenerationProgress[messageID]
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.prompt, "read this aloud")
        XCTAssertTrue(final?.isComplete ?? false)
        XCTAssertNil(final?.error)

        // The completion event must rewrite the placeholder's parts to a single
        // `.generatedMedia` of kind `.audio`.
        let message = try XCTUnwrap(vm.messages.first(where: { $0.id == messageID }))
        XCTAssertEqual(message.contentParts.count, 1)
        guard case .generatedMedia(let media) = message.contentParts.first else {
            return XCTFail("Expected a .generatedMedia part, got \(String(describing: message.contentParts.first))")
        }
        XCTAssertEqual(media.kind, .audio)
        XCTAssertEqual(media.url, audioURL)
    }

    // MARK: - Test 4: failed generation surfaces error

    func test_generateSpeech_failure_surfacesErrorInProgress() async throws {
        struct BoomError: LocalizedError { var errorDescription: String? { "boom" } }

        let backend = MockAudioBackend()
        backend.setPlan(.init(events: [.progress(step: 1, total: 4)], trailingError: BoomError()))

        let (runtime, _) = makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(audioRuntime: runtime)
        vm.activeSession = ChatSession(title: "Fail Test")

        let messageID = try await vm.generateSpeech(
            config: SpeechGenerationConfig(text: "broken")
        )

        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error != nil }
        XCTAssertEqual(vm.audioGenerationProgress[messageID]?.error, "boom")
    }

    // MARK: - Test 5: cancel marks progress complete

    func test_cancelAudioGeneration_marksProgressComplete() async throws {
        let backend = MockAudioBackend()
        // Long-running plan so we can cancel mid-flight.
        backend.setPlan(.init(
            events: (1...20).map { .progress(step: $0, total: 20) },
            delayPerEventNs: 20_000_000  // 20ms each
        ))

        let (runtime, _) = makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(audioRuntime: runtime)
        vm.activeSession = ChatSession(title: "Cancel Test")

        let messageID = try await vm.generateSpeech(
            config: SpeechGenerationConfig(text: "slow")
        )

        // Wait for at least one progress event.
        await awaitProgress(vm, for: messageID) { !$0.isComplete }

        await vm.cancelAudioGeneration(messageID: messageID)
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }
    }

    // MARK: - Test 6: cancel is a no-op when unconfigured

    func test_cancelAudioGeneration_whenUnconfigured_isNoOp() async {
        let vm = makeViewModel()
        XCTAssertNil(vm.audioRuntime)
        // Must not throw or trap — just return.
        await vm.cancelAudioGeneration(messageID: UUID())
    }

    // MARK: - Test 7: reconfigure cancels prior subscription

    func test_configure_reconfigureCancelsPriorSubscription() async throws {
        let backend1 = MockAudioBackend()
        backend1.setPlan(.init(events: [.progress(step: 1, total: 4)]))
        let (runtime1, _) = makeRuntime(backend: backend1)

        let backend2 = MockAudioBackend()
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("avm-reconf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let audioURL = outDir.appendingPathComponent("out.caf")
        try Data([0x00]).write(to: audioURL)
        backend2.setPlan(.init(events: [
            .progress(step: 1, total: 1),
            .completed(audioURL)
        ]))
        let (runtime2, _) = makeRuntime(backend: backend2)

        let vm = makeViewModel()
        vm.configure(audioRuntime: runtime1)
        // Capture the first drain task to assert it's been cancelled after
        // reconfigure.
        let firstDrain = vm.audioRuntimeEventDrainTask
        XCTAssertNotNil(firstDrain)

        vm.configure(audioRuntime: runtime2)
        XCTAssertTrue(firstDrain?.isCancelled ?? false, "Prior drain task should be cancelled")
        XCTAssertNotNil(vm.audioRuntimeEventDrainTask)
        XCTAssertNotIdentical(
            vm.audioRuntime as AnyObject,
            runtime1 as AnyObject
        )

        vm.activeSession = ChatSession(title: "Reconf Test")
        let messageID = try await vm.generateSpeech(
            config: SpeechGenerationConfig(text: "second", outputDirectory: outDir)
        )

        // The new runtime's events feed the dict.
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }
    }
}
