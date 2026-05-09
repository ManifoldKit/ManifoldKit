@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class AppleSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer
    private var continuation: CheckedContinuation<Void, Error>?

    public init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.delegate = self
    }

    public func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopSpeaking()
        try Task.checkCancellation()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        resumeContinuation(with: .failure(CancellationError()))
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.resumeContinuation(with: .success(()))
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.resumeContinuation(with: .failure(CancellationError()))
        }
    }

    private func resumeContinuation(with result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
