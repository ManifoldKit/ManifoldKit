import Foundation

/// Zero-dependency ``VoiceActivityDetector`` using RMS energy with hysteresis and
/// a zero-crossing-rate sanity band. No model, no download — the baseline
/// barge-in detector.
///
/// Hysteresis avoids chattering on the threshold: it takes
/// ``Configuration/onsetFrameCount`` consecutive above-threshold frames to
/// declare `.speechStart`, and ``Configuration/offsetFrameCount`` consecutive
/// below-threshold frames to declare `.speechEnd`. The two energy thresholds
/// differ (``Configuration/speechThreshold`` > ``Configuration/silenceThreshold``)
/// so a signal hovering at the boundary doesn't oscillate.
///
/// The defaults are tuned for ~20 ms frames from `.voiceChat`-mode capture (after
/// echo cancellation), where the assistant's own bleed is already attenuated. A
/// host on noisier hardware can raise ``Configuration/speechThreshold``.
@MainActor
public final class EnergyVoiceActivityDetector: VoiceActivityDetector {

    /// Tunables for the energy detector. All defaults are conservative — they
    /// favour a missed onset over a false barge-in, since a false barge-in cuts
    /// the assistant off mid-sentence.
    public struct Configuration: Sendable {
        /// RMS at or above which a frame counts toward speech onset.
        public var speechThreshold: Float
        /// RMS below which a frame counts toward speech offset. Kept under
        /// ``speechThreshold`` to give the hysteresis band its width.
        public var silenceThreshold: Float
        /// Consecutive speech frames required to emit `.speechStart`.
        public var onsetFrameCount: Int
        /// Consecutive silence frames required to emit `.speechEnd`.
        public var offsetFrameCount: Int
        /// Lower ZCR bound: below this a frame is treated as hum/DC, not speech.
        public var minZeroCrossingRate: Float
        /// Upper ZCR bound: above this a frame is treated as fricative hiss/noise.
        public var maxZeroCrossingRate: Float

        public init(
            speechThreshold: Float = 0.06,
            silenceThreshold: Float = 0.03,
            onsetFrameCount: Int = 3,
            offsetFrameCount: Int = 8,
            minZeroCrossingRate: Float = 0.02,
            maxZeroCrossingRate: Float = 0.8
        ) {
            self.speechThreshold = speechThreshold
            self.silenceThreshold = silenceThreshold
            self.onsetFrameCount = onsetFrameCount
            self.offsetFrameCount = offsetFrameCount
            self.minZeroCrossingRate = minZeroCrossingRate
            self.maxZeroCrossingRate = maxZeroCrossingRate
        }
    }

    private let configuration: Configuration
    private var isInSpeech = false
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func ingest(_ frame: AudioFrame) -> VoiceActivity? {
        let rms = frame.rootMeanSquare
        let zcr = frame.zeroCrossingRate
        let plausibleSpeech = zcr >= configuration.minZeroCrossingRate
            && zcr <= configuration.maxZeroCrossingRate

        if isInSpeech {
            // In speech: accumulate silence toward an offset.
            guard rms < configuration.silenceThreshold else {
                consecutiveSilenceFrames = 0
                return nil
            }
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0
            guard consecutiveSilenceFrames >= configuration.offsetFrameCount else { return nil }
            isInSpeech = false
            consecutiveSilenceFrames = 0
            return .speechEnd
        } else {
            // In silence: accumulate plausible-speech energy toward an onset.
            guard rms >= configuration.speechThreshold, plausibleSpeech else {
                consecutiveSpeechFrames = 0
                return nil
            }
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0
            guard consecutiveSpeechFrames >= configuration.onsetFrameCount else { return nil }
            isInSpeech = true
            consecutiveSpeechFrames = 0
            return .speechStart
        }
    }

    public func reset() {
        isInSpeech = false
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
    }
}
