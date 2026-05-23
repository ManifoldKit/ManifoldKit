@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

@MainActor
public final class AppleSpeechTranscriber: NSObject, SpeechTranscribing {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine: AVAudioEngine
    private let audioSessionCoordinator: VoiceAudioSessionCoordinator

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript: String = ""

    public convenience init(locale: Locale = .current) {
        self.init(
            locale: locale,
            audioEngine: AVAudioEngine(),
            audioSessionCoordinator: VoiceAudioSessionCoordinator()
        )
    }

    init(
        locale: Locale,
        audioEngine: AVAudioEngine = AVAudioEngine(),
        audioSessionCoordinator: VoiceAudioSessionCoordinator = VoiceAudioSessionCoordinator()
    ) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.audioEngine = audioEngine
        self.audioSessionCoordinator = audioSessionCoordinator
        super.init()
    }

    public func requestAuthorization() async -> VoiceAuthorizationStatus {
        guard recognizer != nil else { return .unsupportedLocale }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch speechStatus {
        case .authorized:
            let microphoneGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return microphoneGranted ? .authorized : .microphoneDenied
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw VoiceError.simulatorUnsupported
        #else
        guard let recognizer else { throw VoiceError.unsupportedLocale }
        guard recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }

        stopInternal(clearTranscript: true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let transcript = result.bestTranscription.formattedString
            self.latestTranscript = transcript
            Task { @MainActor in
                onUpdate(SpeechTranscriptionUpdate(text: transcript, isFinal: result.isFinal))
            }
        }

        do {
            try audioSessionCoordinator.activateRecording()
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopInternal(clearTranscript: true)
            throw VoiceError.setupFailed(error.localizedDescription)
        }
        #endif
    }

    public func stopTranscribing() async throws -> String? {
        recognitionRequest?.endAudio()
        stopInternal(clearTranscript: false)
        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    public func cancelTranscribing() {
        stopInternal(clearTranscript: true)
    }

    private func stopInternal(clearTranscript: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioSessionCoordinator.deactivateRecording()
        if clearTranscript {
            latestTranscript = ""
        }
    }
}
