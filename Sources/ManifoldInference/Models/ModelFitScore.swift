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
