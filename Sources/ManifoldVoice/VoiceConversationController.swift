import Foundation
import Observation

@Observable
@MainActor
public final class VoiceConversationController {

    public private(set) var captureState: VoiceCaptureState = .idle
    public private(set) var liveTranscript: String = ""
    public private(set) var lastCommittedTranscript: String?
    public private(set) var recentWakeWordDetection: WakeWordDetection?
    public private(set) var errorMessage: String?
    public private(set) var isSpeaking: Bool = false

    /// Voice/rate/pitch/language applied to spoken utterances. Defaults to
    /// `SpeechOptions()` (system voice, default rate) for source-compatible
    /// behaviour; set it to control continuous read-aloud.
    @ObservationIgnored public var speechOptions: SpeechOptions = SpeechOptions()

    @ObservationIgnored private let transcriber: any SpeechTranscribing
    @ObservationIgnored private let synthesizer: any SpeechSynthesizing
    @ObservationIgnored private let wakeWordDetector: (any WakeWordDetector)?
    @ObservationIgnored private let wakeWordToastDuration: Duration
    @ObservationIgnored private let toastSleeper: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var wakeWordDismissTask: Task<Void, Never>?
    @ObservationIgnored private var activeUtterances = 0

    public init(
        transcriber: (any SpeechTranscribing)? = nil,
        synthesizer: (any SpeechSynthesizing)? = nil,
        wakeWordDetector: (any WakeWordDetector)? = nil,
        wakeWordToastDuration: Duration = .seconds(2),
        toastSleeper: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
        self.synthesizer = synthesizer ?? AppleSpeechSynthesizer()
        self.wakeWordDetector = wakeWordDetector
        self.wakeWordToastDuration = wakeWordToastDuration
        self.toastSleeper = toastSleeper
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
        recentWakeWordDetection = nil
        liveTranscript = ""
        wakeWordDismissTask?.cancel()
        wakeWordDismissTask = nil
        wakeWordDetector?.reset()
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
                if let detection = self.wakeWordDetector?.ingest(update) {
                    self.presentWakeWordDetection(detection)
                }
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
        wakeWordDismissTask?.cancel()
        wakeWordDismissTask = nil
        recentWakeWordDetection = nil

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
        wakeWordDismissTask?.cancel()
        wakeWordDismissTask = nil
        recentWakeWordDetection = nil
        liveTranscript = ""
        lastCommittedTranscript = nil
        wakeWordDetector?.reset()
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

        startPlayback(of: trimmed, enqueue: false)
    }

    /// Append `text` to the speech queue for continuous read-aloud of a sequence
    /// of items. Unlike `togglePlayback`, this does not cancel the in-flight
    /// utterance — successive calls play in order.
    public func enqueueReadback(of text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        startPlayback(of: trimmed, enqueue: true)
    }

    private func startPlayback(of trimmed: String, enqueue: Bool) {
        errorMessage = nil
        if !enqueue {
            playbackTask?.cancel()
            activeUtterances = 0
        }
        activeUtterances += 1
        isSpeaking = true

        let options = speechOptions
        // Each utterance owns its own task so an enqueued readback survives the
        // previous one completing; the most recent task is tracked for cancel.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synthesizer.speak(trimmed, options: options, enqueue: enqueue)
            } catch is CancellationError {
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.activeUtterances = max(0, self.activeUtterances - 1)
            if self.activeUtterances == 0 {
                self.isSpeaking = false
                self.playbackTask = nil
            }
        }
        playbackTask = task
    }

    public func stopSpeaking() {
        synthesizer.stopSpeaking()
        playbackTask?.cancel()
        playbackTask = nil
        activeUtterances = 0
        isSpeaking = false
    }

    private func presentWakeWordDetection(_ detection: WakeWordDetection) {
        recentWakeWordDetection = detection
        wakeWordDismissTask?.cancel()

        wakeWordDismissTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.toastSleeper(self.wakeWordToastDuration)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.wakeWordDismissTask = nil
                }
                return
            }

            await MainActor.run {
                if self.recentWakeWordDetection == detection {
                    self.recentWakeWordDetection = nil
                }
                self.wakeWordDismissTask = nil
            }
        }
    }

    private func setFailure(_ error: Error) {
        captureState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
    }
}
