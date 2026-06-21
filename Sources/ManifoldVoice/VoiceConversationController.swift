import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable
@MainActor
public final class VoiceConversationController {

    public private(set) var captureState: VoiceCaptureState = .idle
    public private(set) var liveTranscript: String = ""
    public private(set) var lastCommittedTranscript: String?
    public private(set) var errorMessage: String?
    public private(set) var isSpeaking: Bool = false

    /// The recovery path the view should offer alongside ``statusText`` when the
    /// last attempt didn't reach recording. `nil` means there's nothing to
    /// recover from. Drives the "Open Settings" / "tap to allow" / "try again"
    /// affordances so a denied permission or an empty transcript is never a dead
    /// end. See ``VoiceRecoveryAffordance``.
    public private(set) var recoveryAffordance: VoiceRecoveryAffordance?

    /// Voice/rate/pitch/language applied to spoken utterances. Defaults to
    /// `SpeechOptions()` (system voice, default rate) for source-compatible
    /// behaviour; set it to control continuous read-aloud.
    @ObservationIgnored public var speechOptions: SpeechOptions = SpeechOptions()

    @ObservationIgnored private let transcriber: any SpeechTranscribing
    @ObservationIgnored private let synthesizer: any SpeechSynthesizing
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var activeUtterances = 0
    /// Monotonic playback-generation token. A replace-mode `startPlayback`
    /// (or `stopSpeaking`) bumps this so a previously-cancelled utterance task
    /// — whose continuation resumes *after* the new utterance has already
    /// started — can detect that it no longer owns the shared `isSpeaking` /
    /// `activeUtterances` state and skip its teardown. Without this, the stale
    /// task's tail would decrement the new generation's counter and clear
    /// `isSpeaking` while a fresh utterance is still speaking.
    @ObservationIgnored private var playbackGeneration = 0

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
        recoveryAffordance = nil
        lastCommittedTranscript = nil
        liveTranscript = ""
        captureState = .requestingPermission

        switch await transcriber.requestAuthorization() {
        case .authorized:
            break
        case .denied:
            // Actively refused: the only way back is the system Settings app.
            setFailure(VoiceError.speechRecognitionDenied, recovery: .openSettings)
            return
        case .restricted:
            // Restricted (e.g. parental controls / MDM): also a Settings path.
            setFailure(VoiceError.speechRecognitionRestricted, recovery: .openSettings)
            return
        case .notDetermined:
            // Never asked yet — this is NOT a denial. Re-tapping the mic
            // re-triggers the OS prompt, so guide the user to allow rather than
            // telling them permission was refused.
            setFailure(VoiceError.speechRecognitionNotDetermined, recovery: .requestAgain)
            return
        case .unsupportedLocale:
            setFailure(VoiceError.unsupportedLocale)
            return
        case .microphoneDenied:
            setFailure(VoiceError.microphoneAccessDenied, recovery: .openSettings)
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
                // Nothing was recognised. Surface a brief, non-blaming nudge
                // instead of silently doing nothing so the user knows the tap
                // registered and what to do next.
                liveTranscript = ""
                errorMessage = Self.nothingRecognizedMessage
                recoveryAffordance = .retry
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
        recoveryAffordance = nil
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
        // Don't read aloud over VoiceOver: it would duck/fight the screen
        // reader's own speech. VoiceOver users already hear content via the
        // screen reader, so suppress the redundant TTS playback.
        guard !isVoiceOverRunning else { return }

        errorMessage = nil
        recoveryAffordance = nil
        if !enqueue {
            playbackTask?.cancel()
            // New generation: any in-flight (now-cancelled) task belongs to the
            // previous generation and must not touch the counter below.
            playbackGeneration += 1
            activeUtterances = 0
        }
        let generation = playbackGeneration
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
                // A stale (replaced) task must not clobber the new utterance's
                // cleared error state; only the current generation reports.
                if generation == self.playbackGeneration {
                    self.errorMessage = error.localizedDescription
                }
            }

            // A cancelled replace-mode predecessor resumes *after* the new
            // utterance already reset the counter; without this guard its tail
            // would decrement the new generation's count and falsely clear
            // `isSpeaking`.
            guard generation == self.playbackGeneration else { return }
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
        // Bump the generation so any cancelled task's tail no-ops instead of
        // re-decrementing the (already-zeroed) counter.
        playbackGeneration += 1
        activeUtterances = 0
        isSpeaking = false
    }

    private func setFailure(_ error: Error, recovery: VoiceRecoveryAffordance? = nil) {
        captureState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
        recoveryAffordance = recovery
    }

    /// Brief, non-blaming nudge shown when the transcript came back empty.
    static let nothingRecognizedMessage = "Didn't catch that — tap to try again."

    /// Whether VoiceOver is currently running. Used to avoid the TTS read-aloud
    /// path fighting VoiceOver's own speech (it would talk over the screen
    /// reader). Always `false` off-iOS where the property is unavailable.
    var isVoiceOverRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }

    /// Opens the OS settings surface so the user can grant a previously
    /// denied/restricted microphone or speech permission. On iOS this deep-links
    /// straight to the app's settings pane; on macOS it opens System Settings.
    /// Elsewhere it is a no-op (the view should fall back to a textual hint).
    public func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        // The microphone privacy pane. Uses the modern System Settings URL
        // scheme — the legacy `com.apple.preference.security` host was
        // deprecated in macOS 13 and no longer deep-links to the pane on the
        // supported macOS 15+ floor. System Settings opens to its root if the
        // anchor can't be resolved, so this degrades gracefully.
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
