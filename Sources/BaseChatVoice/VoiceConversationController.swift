import Foundation
import Observation

@Observable
@MainActor
public final class VoiceConversationController {

    public private(set) var captureState: VoiceCaptureState = .idle
    public private(set) var liveTranscript: String = ""
    public private(set) var lastCommittedTranscript: String?
    public private(set) var errorMessage: String?
    public private(set) var isSpeaking: Bool = false

    @ObservationIgnored private let transcriber: any SpeechTranscribing
    @ObservationIgnored private let synthesizer: any SpeechSynthesizing
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    public init(
        transcriber: (any SpeechTranscribing)? = nil,
        synthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
        self.synthesizer = synthesizer ?? AppleSpeechSynthesizer()
    }

    public var isRecording: Bool {
        captureState == .recording
    }

    public var showsTranscriptPreview: Bool {
        switch captureState {
        case .recording, .processing:
            true
        case .idle, .requestingPermission:
            !liveTranscript.isEmpty
        case .failed:
            false
        }
    }

    public var statusText: String? {
        if let errorMessage {
            return errorMessage
        }
        if isSpeaking {
            return "Reading the last assistant reply aloud…"
        }
        switch captureState {
        case .idle:
            return nil
        case .requestingPermission:
            return "Requesting microphone and speech access…"
        case .recording:
            return "Listening…"
        case .processing:
            return "Finishing transcript…"
        case .failed(let message):
            return message
        }
    }

    public func startRecording() async {
        guard captureState != .recording, captureState != .processing else { return }

        stopSpeaking()
        errorMessage = nil
        lastCommittedTranscript = nil
        liveTranscript = ""
        captureState = .requestingPermission

        switch await transcriber.requestAuthorization() {
        case .authorized:
            break
        case .denied:
            setFailure(VoiceError.speechRecognitionDenied)
            return
        case .restricted:
            setFailure(VoiceError.speechRecognitionRestricted)
            return
        case .notDetermined:
            setFailure(VoiceError.speechRecognitionDenied)
            return
        case .unsupportedLocale:
            setFailure(VoiceError.unsupportedLocale)
            return
        case .microphoneDenied:
            setFailure(VoiceError.microphoneAccessDenied)
            return
        }

        do {
            try await transcriber.startTranscribing { [weak self] update in
                guard let self else { return }
                self.liveTranscript = update.text
            }
            captureState = .recording
        } catch {
            setFailure(error)
        }
    }

    @discardableResult
    public func stopRecording() async -> String? {
        guard captureState == .recording || captureState == .processing else { return nil }
        captureState = .processing

        do {
            let transcript = try await transcriber.stopTranscribing()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSource = transcript.flatMap { $0.isEmpty ? nil : $0 } ?? liveTranscript
            let resolved = resolvedSource.trimmingCharacters(in: .whitespacesAndNewlines)

            captureState = .idle
            guard !resolved.isEmpty else {
                liveTranscript = ""
                return nil
            }

            liveTranscript = resolved
            lastCommittedTranscript = resolved
            return resolved
        } catch {
            setFailure(error)
            return nil
        }
    }

    public func cancelRecording() {
        transcriber.cancelTranscribing()
        liveTranscript = ""
        lastCommittedTranscript = nil
        errorMessage = nil
        if case .failed = captureState {
            captureState = .idle
        } else if captureState != .idle {
            captureState = .idle
        }
    }

    public func togglePlayback(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isSpeaking {
            stopSpeaking()
            return
        }

        errorMessage = nil
        playbackTask?.cancel()
        isSpeaking = true

        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synthesizer.speak(trimmed)
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                self.isSpeaking = false
                self.playbackTask = nil
            }
        }
    }

    public func stopSpeaking() {
        synthesizer.stopSpeaking()
        playbackTask?.cancel()
        playbackTask = nil
        isSpeaking = false
    }

    private func setFailure(_ error: Error) {
        captureState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
    }
}
