@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class AppleSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer

    // One continuation per in-flight utterance. AVSpeechSynthesizer can queue
    // multiple utterances; each `speak` call awaits the completion of its own
    // utterance, so we key continuations by utterance identity rather than
    // holding a single shared one.
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuations[ObjectIdentifier(utterance)] = continuation
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
        for continuation in pending.values {
            continuation.resume(throwing: CancellationError())
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
        guard let continuation = continuations.removeValue(forKey: key) else { return }
        continuation.resume(with: result)
    }
}
