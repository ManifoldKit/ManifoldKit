@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for the ``ChatViewModel`` voice-selection surface added for the
/// TTS voice picker: voice enumeration, the ``selectedSpeechVoiceID`` binding,
/// and that ``ChatViewModel/generateSpeech(forText:)`` threads the selected
/// voice into the ``SpeechGenerationConfig`` the backend receives.
@MainActor
final class ChatViewModelVoiceSelectionTests: XCTestCase {

    // MARK: - Recording backend (captures the config it was handed)

    final class RecordingAudioBackend: AudioGenerationBackend, @unchecked Sendable {
        private let box = OSAllocatedUnfairLock<SpeechGenerationConfig?>(initialState: nil)
        var lastConfig: SpeechGenerationConfig? { box.withLock { $0 } }

        var isGenerating: Bool { false }
        func stopGeneration() {}

        func generate(
            config: SpeechGenerationConfig
        ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error> {
            box.withLock { $0 = config }
            return AsyncThrowingStream { continuation in
                continuation.yield(.progress(step: 1, total: 1))
                continuation.yield(.completed(URL(fileURLWithPath: "/tmp/voice-test.caf")))
                continuation.finish()
            }
        }
    }

    @MainActor
    final class TestMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        func insertMessage(_ message: ChatMessage) async throws { messages[message.id] = message }
        func updateMessage(_ message: ChatMessage) async throws { messages[message.id] = message }
        func deleteMessage(_ messageID: UUID) async throws { messages.removeValue(forKey: messageID) }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values.filter { $0.sessionID == sessionID }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelVoiceSelectionTests-\(UUID().uuidString)")!
        )
    }

    @discardableResult
    private func configure(_ vm: ChatViewModel, backend: RecordingAudioBackend) -> UUID {
        let service = AudioGenerationService(backend: backend)
        let runtime = AudioGenerationRuntime(service: service, messageStore: TestMessageStore())
        vm.configure(audioRuntime: runtime)
        let session = ChatSession(title: "Voice Test")
        vm.activeSession = session
        return session.id
    }

    /// Spin until the recording backend captures a config, or fail.
    private func awaitConfig(
        _ backend: RecordingAudioBackend,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> SpeechGenerationConfig? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let config = backend.lastConfig { return config }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for backend to receive a config", file: file, line: line)
        return nil
    }

    // MARK: - Enumeration

    func test_availableSpeechVoices_isNonEmptyAndRankedBestFirst() {
        let vm = makeViewModel()
        let voices = vm.availableSpeechVoices()
        XCTAssertFalse(voices.isEmpty, "Expected installed system voices")
        // Quality is the dominant ranking key, so qualities must be non-increasing.
        let qualities = voices.map(\.quality.rawValue)
        XCTAssertEqual(qualities, qualities.sorted(by: >), "Voices must be ranked best-first")
    }

    func test_availableSpeechVoices_languageFilterRestrictsResults() {
        let vm = makeViewModel()
        let english = vm.availableSpeechVoices(language: "en")
        XCTAssertTrue(english.allSatisfy { $0.language.lowercased().hasPrefix("en") })
    }

    // MARK: - Selection threading

    func test_selectedVoiceDefaultsToNil() {
        XCTAssertNil(makeViewModel().selectedSpeechVoiceID)
    }

    func test_generateSpeechForText_threadsSelectedVoiceIntoConfig() async throws {
        let vm = makeViewModel()
        let backend = RecordingAudioBackend()
        _ = configure(vm, backend: backend)

        let chosen = try XCTUnwrap(vm.availableSpeechVoices().first)
        vm.selectedSpeechVoiceID = chosen.id

        try await vm.generateSpeech(forText: "Hello voices.")

        let config = await awaitConfig(backend)
        XCTAssertEqual(config?.voice, chosen.id, "Selected voice must be threaded into the config")
        XCTAssertEqual(config?.text, "Hello voices.")
    }

    func test_generateSpeechForText_nilSelection_leavesVoiceNilForBackendAutoSelect() async throws {
        let vm = makeViewModel()
        let backend = RecordingAudioBackend()
        _ = configure(vm, backend: backend)

        XCTAssertNil(vm.selectedSpeechVoiceID)
        try await vm.generateSpeech(forText: "Auto voice.")

        let config = await awaitConfig(backend)
        XCTAssertNil(config?.voice, "Nil selection must leave voice nil so the backend auto-selects")
        XCTAssertEqual(config?.text, "Auto voice.")
    }
}
