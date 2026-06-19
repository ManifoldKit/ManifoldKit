@preconcurrency import AVFoundation
import Foundation

/// Zero-dependency, in-core reference ``AudioGenerationBackend`` backed by
/// Apple's `AVSpeechSynthesizer`.
///
/// Renders a text prompt to an audio file (CAF) using
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` — the *render-to-file*
/// path, **not** the speaker-playback path used by `ManifoldVoice`'s
/// `AppleSpeechSynthesizer` (Lane 1 vs Lane 2 in the audio-generation design
/// doc: this is the artifact-generation lane). The two share the same engine
/// but serve different contracts.
///
/// Available on macOS + iOS with no external dependency or model download — the
/// system voices are always resident, so the backend needs no `loadModel`
/// step (see ``AudioGenerationBackend`` for the rationale).
///
/// ## Concurrency
///
/// Reference type with a fine-grained `NSLock`, mirroring the
/// ``ImageGenerationBackend`` isolation strategy. `generate(config:)` returns
/// synchronously after the synchronous-throw entrypoint; the actual render
/// runs inside the returned `AsyncThrowingStream`'s producer task, off any
/// caller actor. ``stopGeneration()`` flips a lock-protected cancellation flag
/// the render loop polls, so a main-actor cancel does not block on the render.
public final class AppleTTSBackend: AudioGenerationBackend, @unchecked Sendable {

    /// Errors surfaced by the Apple TTS render path.
    public enum BackendError: Error, Equatable, Sendable {
        /// The supplied `voice` identifier did not resolve to an installed
        /// system voice and no usable fallback was available.
        case voiceUnavailable(String)
        /// `AVSpeechSynthesizer.write` produced no audio buffers — typically an
        /// empty prompt or a synthesiser that declined to render.
        case noAudioProduced
        /// The output file could not be created or written.
        case fileWriteFailed
    }

    private struct State {
        var isGenerating = false
        var cancelled = false
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    public var isGenerating: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.isGenerating
    }

    public func stopGeneration() {
        lock.lock(); defer { lock.unlock() }
        // No-op when idle. When a render is running, flip the cancel flag the
        // producer task polls between buffers; the task clears `isGenerating`
        // once it observes the flag and tears down.
        guard state.isGenerating else { return }
        state.cancelled = true
    }

    public func generate(
        config: SpeechGenerationConfig
    ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error> {
        let trimmed = config.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BackendError.noAudioProduced
        }

        // Resolve the destination up front so a bad output directory surfaces
        // synchronously rather than mid-stream.
        let outputURL = Self.makeOutputURL(directory: config.outputDirectory)

        lock.lock()
        // Latest-wins: a fresh generate clears any stale cancel flag.
        state = State(isGenerating: true, cancelled: false)
        lock.unlock()

        return AsyncThrowingStream { continuation in
            // Render off any caller actor. AVSpeechSynthesizer.write fires its
            // buffer callback synchronously on an internal queue during the
            // call; we drive it from a detached task and accumulate buffers
            // into an AVAudioFile.
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try await self.render(
                        text: trimmed,
                        config: config,
                        outputURL: outputURL,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    self.finishGenerating()
                    continuation.finish()
                } catch {
                    self.finishGenerating()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [self] termination in
                if case .cancelled = termination {
                    self.stopGeneration()
                }
                task.cancel()
            }
        }
    }

    // MARK: - Render

    private func finishGenerating() {
        lock.lock(); defer { lock.unlock() }
        state.isGenerating = false
        state.cancelled = false
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.cancelled
    }

    /// Drives `AVSpeechSynthesizer.write` to completion, writing each rendered
    /// buffer into `outputURL` and yielding progress ticks. Emits the terminal
    /// `.completed(outputURL)` once the synthesiser signals end-of-stream.
    private func render(
        text: String,
        config: SpeechGenerationConfig,
        outputURL: URL,
        continuation: AsyncThrowingStream<AudioGenerationEvent, Error>.Continuation
    ) async throws {
        let utterance = Self.makeUtterance(text: text, config: config)

        // The write callback fires synchronously on an internal queue; we
        // bridge it to the async producer via a continuation that resumes when
        // the synthesiser signals the terminal (zero-frame) buffer. A class box
        // collects render state shared between the callback thread and the
        // resume site — guarded by its own lock because the callback can fire
        // on a different thread than the awaiting task.
        final class RenderBox: @unchecked Sendable {
            let lock = NSLock()
            var audioFile: AVAudioFile?
            var bufferCount = 0
            var error: Error?
            var finished = false

            // `withLock` is async-safe (the synchronous closure cannot suspend),
            // unlike calling `lock.lock()/unlock()` directly across an `await`.
            func withLock<R>(_ body: () -> R) -> R {
                lock.lock(); defer { lock.unlock() }
                return body()
            }
        }
        let box = RenderBox()
        let synthesizer = AVSpeechSynthesizer()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `resumeOnce` guards against the (unlikely) double-resume if the
            // synthesiser ever delivers two terminal buffers.
            let resumeState = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Void, Error>) {
                resumeState.lock()
                let alreadyResumed = resumed
                resumed = true
                resumeState.unlock()
                guard !alreadyResumed else { return }
                cont.resume(with: result)
            }

            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    // Non-PCM buffer — nothing to write; ignore.
                    return
                }

                // A zero-frame buffer is the synthesiser's end-of-stream
                // signal.
                if pcm.frameLength == 0 {
                    let (produced, writeError): (Int, Error?) = box.withLock {
                        box.finished = true
                        return (box.bufferCount, box.error)
                    }

                    if let writeError {
                        resumeOnce(.failure(writeError))
                    } else if produced == 0 {
                        resumeOnce(.failure(BackendError.noAudioProduced))
                    } else {
                        resumeOnce(.success(()))
                    }
                    return
                }

                // Cooperative cancellation: stop appending once cancelled. We
                // still let the synthesiser run to its terminal buffer (it owns
                // its own queue) but produce no further output.
                if self.isCancelled() {
                    resumeOnce(.failure(CancellationError()))
                    return
                }

                let yieldedStep: Int? = box.withLock {
                    if box.error != nil { return nil }
                    do {
                        if box.audioFile == nil {
                            box.audioFile = try AVAudioFile(
                                forWriting: outputURL,
                                settings: pcm.format.settings
                            )
                        }
                        try box.audioFile?.write(from: pcm)
                        box.bufferCount += 1
                        return box.bufferCount
                    } catch {
                        box.error = error
                        return nil
                    }
                }
                if let step = yieldedStep {
                    // Unknown total ahead of time — report step==total so
                    // consumers clamp to a monotonically-growing fraction.
                    continuation.yield(.progress(step: step, total: step))
                }
            }
        }

        // Drop the file handle (closes/flushes) before emitting completion so
        // the file at `outputURL` is fully written when the consumer reads it.
        box.withLock { box.audioFile = nil }

        if isCancelled() {
            finishGenerating()
            continuation.finish()
            return
        }

        finishGenerating()
        continuation.yield(.completed(outputURL))
        continuation.finish()
    }

    // MARK: - Helpers

    /// Builds the destination URL. Honours ``SpeechGenerationConfig/outputDirectory``
    /// when set (per the ``AudioGenerationBackend`` output contract), otherwise
    /// falls back to the temporary directory. CAF container — the native format
    /// `AVAudioFile` writes from `AVSpeechSynthesizer`'s buffer format without a
    /// re-encode.
    static func makeOutputURL(directory: URL?) -> URL {
        let base = directory ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("tts-\(UUID().uuidString).caf")
    }

    /// Maps a ``SpeechGenerationConfig`` onto an `AVSpeechUtterance`. Honours
    /// `voice`, `rate`, and `pitch`; ignores knobs the engine does not expose.
    static func makeUtterance(
        text: String,
        config: SpeechGenerationConfig
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let rate = config.rate {
            utterance.rate = rate
        }
        if let pitch = config.pitch {
            utterance.pitchMultiplier = pitch
        }
        if let voiceID = config.voice {
            // Try an explicit voice identifier first, then a BCP-47 language
            // tag (callers commonly pass e.g. "en-US"). Leaving `voice` nil
            // lets the system pick the default voice.
            if let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                utterance.voice = voice
            } else if let voice = AVSpeechSynthesisVoice(language: voiceID) {
                utterance.voice = voice
            }
        }
        return utterance
    }
}
