import Foundation

/// A slice of captured mono PCM audio handed to a ``VoiceActivityDetector``.
///
/// Samples are normalised to `[-1, 1]`. A frame is the unit the barge-in
/// listener delivers *while the assistant is speaking*; the detector inspects a
/// running stream of them to decide when the user has started or stopped
/// talking. The type is `Sendable` so it can cross from the audio capture thread
/// to the main actor unchanged.
public struct AudioFrame: Sendable, Equatable {
    /// Mono PCM samples, normalised to `[-1, 1]`.
    public let samples: [Float]

    /// Sample rate in Hz of ``samples`` (for example `48_000`).
    public let sampleRate: Double

    /// Whether this frame is known to be the assistant's own synthesized output
    /// looping back into the microphone (acoustic echo).
    ///
    /// The *primary* self-barge-in mitigation is Apple's `.voiceChat` acoustic
    /// echo cancellation (see ``VoiceAudioSessionCoordinator/activateDuplex()``),
    /// which removes most of the assistant's own output before it reaches a
    /// detector — but AEC is **best-effort**: on a route where it underperforms
    /// (loud speaker output, some Bluetooth paths) residual bleed can still read
    /// as speech onset. This flag is a *secondary*, explicit guard for a capture
    /// path that can label echo — the controller refuses to feed a tagged frame
    /// to the detector. The production ``AVAudioEngineFrameStream`` does not
    /// currently tag echo (it relies on AEC), so today the flag is exercised by
    /// the barge-in tests and reserved for a future capture path that can label
    /// residual echo. Defaults to `false`.
    public let isEcho: Bool

    public init(samples: [Float], sampleRate: Double, isEcho: Bool = false) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.isEcho = isEcho
    }

    /// Root-mean-square amplitude of ``samples`` in `[0, 1]` — the primary energy
    /// signal an energy-threshold detector keys on. `0` for an empty frame.
    public var rootMeanSquare: Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Fraction of adjacent-sample sign changes in `[0, 1]` — the zero-crossing
    /// rate.
    ///
    /// Voiced speech sits in a mid band; a very high ZCR is typically fricative
    /// hiss/noise and a very low ZCR is a hum or DC offset. An energy detector
    /// uses it to reject non-speech energy that the RMS gate alone would accept.
    public var zeroCrossingRate: Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index] >= 0) != (samples[index - 1] >= 0) {
            crossings += 1
        }
        return Float(crossings) / Float(samples.count - 1)
    }
}
