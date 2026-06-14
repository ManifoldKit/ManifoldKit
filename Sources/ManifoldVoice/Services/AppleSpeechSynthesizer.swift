@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class AppleSpeechSynthesizer: NSObject, SpeechSynthesizing, SpeechProgressReporting, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer

    // One continuation per in-flight utterance. AVSpeechSynthesizer can queue
    // multiple utterances; each `speak` call awaits the completion of its own
    // utterance, so we key continuations by utterance identity rather than
    // holding a single shared one.
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    // A stable id per queued utterance, surfaced through `SpeechProgress` so a
    // host can correlate range callbacks with the utterance being spoken.
    private var utteranceIDs: [ObjectIdentifier: UUID] = [:]

    public var onSpeechProgress: (@MainActor (SpeechProgress) -> Void)?

    public init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.delegate = self
    }

    public func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Replace mode (default) cancels whatever is currently queued/speaking.
        // Enqueue mode leaves the queue intact so the new utterance plays after
        // the current one finishes — AVSpeechSynthesizer queues utterances as
        // long as we don't stop it.
        if !enqueue {
            stopSpeaking()
        }
        try Task.checkCancellation()

        let utterance = Self.makeUtterance(string: trimmed, options: options)

        let key = ObjectIdentifier(utterance)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuations[key] = continuation
            self.utteranceIDs[key] = UUID()
            synthesizer.speak(utterance)
        }
    }

    /// Builds a configured utterance. Extracted so the options→utterance mapping
    /// is exercised in isolation by tests.
    static func makeUtterance(string: String, options: SpeechOptions) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: string)
        utterance.rate = options.rate ?? AVSpeechUtteranceDefaultSpeechRate
        if let pitch = options.pitchMultiplier {
            utterance.pitchMultiplier = pitch
        }
        if let identifier = options.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let locale = options.locale,
                  let voice = AVSpeechSynthesisVoice(language: locale) {
            utterance.voice = voice
        }
        return utterance
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Fail every queued utterance — stop clears the whole queue, not just the
        // utterance currently being spoken.
        let pending = continuations
        continuations.removeAll()
        utteranceIDs.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: CancellationError())
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        // Read the utterance text synchronously in the delegate callback and hop
        // to the main actor with only Sendable values (String + NSRange), never
        // the non-Sendable AVSpeechUtterance.
        let text = utterance.speechString
        Task { @MainActor in
            self.emitProgress(key: key, nsRange: characterRange, text: text)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.resumeContinuation(for: key, with: .success(()))
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.resumeContinuation(for: key, with: .failure(CancellationError()))
        }
    }

    private func resumeContinuation(for key: ObjectIdentifier, with result: Result<Void, Error>) {
        utteranceIDs.removeValue(forKey: key)
        guard let continuation = continuations.removeValue(forKey: key) else { return }
        continuation.resume(with: result)
    }

    private func emitProgress(key: ObjectIdentifier, nsRange: NSRange, text: String) {
        guard let handler = onSpeechProgress, let id = utteranceIDs[key],
              let progress = Self.makeProgress(utteranceID: id, nsRange: nsRange, text: text) else { return }
        handler(progress)
    }

    /// Maps a delegate `(NSRange, text)` callback into a ``SpeechProgress``,
    /// converting the UTF-16 `NSRange` into Swift `String.Index` range. Returns
    /// `nil` when the range cannot be located in `text` (e.g. out of bounds).
    /// Extracted so the conversion is exercised in isolation by tests.
    static func makeProgress(utteranceID: UUID, nsRange: NSRange, text: String) -> SpeechProgress? {
        guard let range = Range(nsRange, in: text) else { return nil }
        return SpeechProgress(utteranceID: utteranceID, text: text, spokenRange: range)
    }
}
