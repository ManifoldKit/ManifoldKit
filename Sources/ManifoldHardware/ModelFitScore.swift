import Foundation

// Algorithm inspired by llmfit (https://github.com/AlexsJones/llmfit),
// MIT License, © Alex Jones. Reimplemented natively in Swift; no Rust dependency.
//
// This file defines the pure value types for a model-fit *scoring/ranking* layer.
// It complements — and does NOT replace — the existing fit machinery
// (`ModelLoadPlan`, `ModelCapabilityTier`, `DownloadableModelGroup.recommendedVariant`).
// The scorer ranks downloadable models by a composite of four dimensions
// (quality, speed, fit, context) using use-case-specific weights, so the UI can
// surface "best for coding" / "best for chat" orderings without changing the
// authoritative will-it-run gate that `ModelLoadPlan` owns.

/// A task category that biases how the four fit dimensions are weighted.
///
/// Each case carries both the dimension `weights` used to compute the composite
/// score and a `contextNeed` — the rough working-context budget the use case
/// benefits from. The weights encode intent, not measurement: e.g. `chat` favours
/// responsiveness (speed) while `reasoning` favours quality.
public enum ModelUseCase: String, Codable, Sendable, CaseIterable {
    case general
    case coding
    case reasoning
    case chat
    case multimodal
    case embedding

    /// Dimension weights for this use case. Weights sum to 1.0 so the composite
    /// stays in the same 0...1 range as the individual dimensions.
    public var weights: FitWeights {
        switch self {
        // Balanced default — no dimension dominates.
        case .general:
            return FitWeights(quality: 0.30, speed: 0.25, fit: 0.25, context: 0.20)
        // Coding rewards capable models with room for large files/diffs in context.
        case .coding:
            return FitWeights(quality: 0.35, speed: 0.15, fit: 0.20, context: 0.30)
        // Reasoning is quality-dominant; latency matters least.
        case .reasoning:
            return FitWeights(quality: 0.50, speed: 0.10, fit: 0.20, context: 0.20)
        // Interactive chat rewards responsiveness above raw capability.
        case .chat:
            return FitWeights(quality: 0.20, speed: 0.45, fit: 0.25, context: 0.10)
        // Multimodal needs capable models and generous context for image tokens.
        case .multimodal:
            return FitWeights(quality: 0.35, speed: 0.15, fit: 0.20, context: 0.30)
        // Embedding models are small and run in tight loops — speed and fit dominate;
        // long generation context is largely irrelevant.
        case .embedding:
            return FitWeights(quality: 0.20, speed: 0.40, fit: 0.35, context: 0.05)
        }
    }

    /// Rough working-context budget (in tokens) this use case benefits from.
    ///
    /// Used to normalise the context dimension: a model whose (known) context
    /// length meets or exceeds this need scores 1.0 on context. Pre-download,
    /// context length is usually unknown (see `ModelFitScorer`), so this is only
    /// applied for curated models with a declared `contextSize`.
    public var contextNeed: Int {
        switch self {
        case .general:    return 8_192
        case .coding:     return 32_768
        case .reasoning:  return 16_384
        case .chat:       return 4_096
        case .multimodal: return 32_768
        case .embedding:  return 512
        }
    }
}

/// Per-dimension weights for the composite fit score. Conventionally sums to 1.0.
public struct FitWeights: Sendable, Equatable {
    public let quality: Double
    public let speed: Double
    public let fit: Double
    public let context: Double

    public init(quality: Double, speed: Double, fit: Double, context: Double) {
        self.quality = quality
        self.speed = speed
        self.fit = fit
        self.context = context
    }
}

/// A composite fit score for a single model under a given use case.
///
/// The four dimensions are each normalised to 0...1; `composite` is their
/// weighted sum (also 0...1) using the use case's `FitWeights`. `Comparable`
/// orders by `composite` so a `[ModelFitScore]` sorts best-first with `.sorted().reversed()`
/// or worst-first with `.sorted()`.
public struct ModelFitScore: Sendable, Comparable, Equatable {
    /// Capability proxy derived from model size tier + quantization bits (0...1).
    public let quality: Double
    /// Throughput proxy: device memory bandwidth ÷ model footprint, normalised (0...1).
    public let speed: Double
    /// Will-it-run proxy derived from `ModelLoadPlan` verdict + headroom (0...1).
    public let fit: Double
    /// Context-window proxy vs. the use case's need (0...1). Neutral when unknown.
    public let context: Double
    /// Weighted composite of the four dimensions (0...1).
    public let composite: Double

    /// Rough estimated decode throughput used to derive `speed`, surfaced for display.
    public let estimatedTokensPerSecond: Double
    /// Estimated total resident + KV footprint from the load plan, surfaced for display.
    public let memoryBytes: UInt64
    /// Whether `ModelLoadPlan` judged the model loadable on the target device.
    public let willRun: Bool

    public init(
        quality: Double,
        speed: Double,
        fit: Double,
        context: Double,
        composite: Double,
        estimatedTokensPerSecond: Double,
        memoryBytes: UInt64,
        willRun: Bool
    ) {
        self.quality = quality
        self.speed = speed
        self.fit = fit
        self.context = context
        self.composite = composite
        self.estimatedTokensPerSecond = estimatedTokensPerSecond
        self.memoryBytes = memoryBytes
        self.willRun = willRun
    }

    public static func < (lhs: ModelFitScore, rhs: ModelFitScore) -> Bool {
        lhs.composite < rhs.composite
    }
}

// MARK: - Honest qualitative abstractions

// The dimensions above (`composite`, `estimatedTokensPerSecond`, …) are raw,
// continuous proxies. Showing a user a bare "12.7 tok/s" or "fit 0.62" reads as
// a measured fact when it is a coarse pre-download *estimate* — and a confidently
// wrong number erodes trust faster than honest vagueness does. These abstractions
// collapse the raw values into a small number of qualitative buckets the UI can
// present without implying false precision. Power users still read the raw fields.

/// A coarse, reading-pace bucket for decode throughput.
///
/// Derived from `ModelFitScore.estimatedTokensPerSecond`. The thresholds are tuned
/// for *chat-style reading pace* — the rate at which streamed text feels responsive
/// to a person reading along — not for batch throughput. They are deliberately
/// coarse: the underlying estimate is bandwidth ÷ footprint, accurate only to a
/// factor, so finer buckets would imply precision we do not have.
///
/// - Note: This is approximate guidance, not a guarantee. Real throughput depends
///   on prompt length, sampler, thermal state, and concurrent load.
public enum SpeedClass: Sendable, Equatable, CaseIterable {
    /// At or above comfortable reading pace; streaming keeps ahead of the eye.
    case fast
    /// Readable but visibly streaming; fine for interactive chat.
    case usable
    /// Noticeably slow — usable for short replies, tedious for long ones.
    case sluggish
    /// Below the threshold where interactive use is reasonable.
    case tooSlow

    /// Buckets a tokens/sec estimate.
    ///
    /// Thresholds (tok/s): `≥ 30` fast · `12...<30` usable · `5...<12` sluggish ·
    /// `< 5` tooSlow. ~30 tok/s is roughly fast adult silent-reading pace (~5 words/s
    /// ≈ a token every 130 ms), so the stream stays ahead of the reader. Below ~5
    /// tok/s a sentence takes long enough to feel broken for chat. The exact cuts are
    /// judgement calls on a noisy estimate, hence the wide bands.
    public init(tokensPerSecond: Double) {
        switch tokensPerSecond {
        case 30...:      self = .fast
        case 12..<30:    self = .usable
        case 5..<12:     self = .sluggish
        default:         self = .tooSlow
        }
    }

    /// Short, plain-language label suitable for a badge. No punctuation or marketing tone.
    public var label: String {
        switch self {
        case .fast:     return "Fast"
        case .usable:   return "Usable"
        case .sluggish: return "Sluggish"
        case .tooSlow:  return "Too slow"
        }
    }
}

/// A coarse quality bucket for the composite fit score.
///
/// Derived from `ModelFitScore.composite`. Buckets, not a percentage: a "62%" reads
/// as a precise measurement, but the composite is a weighted sum of four estimates,
/// so we present a band instead. A `.notRecommended` model is one the device cannot
/// run well (or at all) — see `ModelFitScore.fitQuality` for the won't-run override.
///
/// - Note: Approximate guidance, not a guarantee.
public enum FitQuality: Sendable, Equatable, CaseIterable {
    /// Strong match for the device and use case.
    case excellent
    /// Solid, workable match.
    case good
    /// Runs, but with real trade-offs (slow, tight on memory, or weak for the task).
    case marginal
    /// Not a sensible choice on this device — typically won't run, or runs badly.
    case notRecommended

    /// Buckets a composite score in 0...1.
    ///
    /// Thresholds: `≥ 0.70` excellent · `0.50...<0.70` good · `0.30...<0.50` marginal ·
    /// `< 0.30` notRecommended. These align with the scorer's `willRun` collapse
    /// (a denied model's composite is multiplied by 0.1), so non-runnable candidates
    /// land in `notRecommended` without a special case here.
    public init(composite: Double) {
        switch composite {
        case 0.70...:    self = .excellent
        case 0.50..<0.70: self = .good
        case 0.30..<0.50: self = .marginal
        default:         self = .notRecommended
        }
    }

    /// Short, plain-language label suitable for a badge.
    public var label: String {
        switch self {
        case .excellent:      return "Excellent"
        case .good:           return "Good"
        case .marginal:       return "Marginal"
        case .notRecommended: return "Not recommended"
        }
    }
}

extension ModelFitScore {
    /// The reading-pace speed bucket for this score's `estimatedTokensPerSecond`.
    ///
    /// Prefer this over the raw `estimatedTokensPerSecond` in user-facing UI: the
    /// estimate is approximate, and a bucket is honest about that. The raw value
    /// remains available for power users and tests.
    public var speedClass: SpeedClass {
        SpeedClass(tokensPerSecond: estimatedTokensPerSecond)
    }

    /// The qualitative quality bucket for this score's `composite`.
    ///
    /// A model that `willRun == false` is always `.notRecommended` regardless of the
    /// composite band — the scorer already collapses its composite, but we assert it
    /// here too so callers cannot surface a "marginal" badge on something that will
    /// not load. Approximate guidance, not a guarantee.
    public var fitQuality: FitQuality {
        guard willRun else { return .notRecommended }
        return FitQuality(composite: composite)
    }

    /// A one-line, factual "why" assembled from the dominant dimensions and `willRun`.
    ///
    /// Intended as the single human-readable justification a UI shows on a recommended
    /// model. It is generated from the same buckets as `speedClass`/`fitQuality`, never
    /// from raw decimals, so it stays honest about precision. No exclamation marks, no
    /// marketing tone — just what the device can and cannot do.
    ///
    /// - Note: Approximate guidance, not a guarantee.
    public var rationale: String {
        // A model that will not load has nothing else worth saying.
        guard willRun else {
            return "Too large to run well on this device"
        }

        var clauses: [String] = []

        // Speed clause — the dimension users feel most directly.
        switch speedClass {
        case .fast:     clauses.append("fast on your device")
        case .usable:   clauses.append("usable speed on your device")
        case .sluggish: clauses.append("slower on your device")
        case .tooSlow:  clauses.append("very slow on your device")
        }

        // Memory headroom clause, from the fit dimension. `fit == 1.0` is an
        // `.allow` verdict (comfortable); `0.5` is `.warn` (tight).
        if fit >= 1.0 {
            clauses.append("fits comfortably")
        } else if fit > 0 {
            clauses.append("a tight fit in memory")
        }

        // Capability clause only when quality is a genuine strength, to avoid
        // padding every line. ~0.7 is the boundary into the capable/frontier tiers.
        if quality >= 0.7 {
            clauses.append("strong capability")
        } else if quality < 0.35 {
            clauses.append("limited capability")
        }

        // Sentence-case the first clause; join the rest with middots for a compact line.
        guard let first = clauses.first else {
            // Defensive: speedClass always contributes a clause, so this is unreachable.
            return "Runnable on this device"
        }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        let rest = clauses.dropFirst()
        return ([head] + rest).joined(separator: " · ")
    }
}
