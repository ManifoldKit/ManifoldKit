import Foundation

/// Runs a short inference benchmark against a loaded model and returns performance metadata.
public protocol ModelBenchmarkRunner: Sendable {
    /// Runs the benchmark for the given model and returns a result.
    ///
    /// The model must already be loaded in the relevant `InferenceService` before calling this.
    /// - Throws: Any error produced by the underlying inference engine.
    func runBenchmark(for model: ModelInfo) async throws -> ModelBenchmarkResult
}

/// Default benchmark runner that fires a short fixed prompt and measures token throughput.
///
/// The model must already be loaded in the provided ``InferenceService`` before calling
/// ``runBenchmark(for:)``. The runner generates up to 64 tokens and records the elapsed
/// wall-clock time to compute tokens-per-second.
///
/// ## What the returned result contains
///
/// - **`tokensPerSecond`** — the actual measured throughput on this device. This is the
///   primary value produced by the benchmark run.
/// - **`tier`** — a *static* file-size estimate computed by
///   ``ModelCapabilityTier/estimate(from:)``. The benchmark does **not** update the tier;
///   mapping tokens/sec to a tier requires hardware-specific thresholds that this runner
///   intentionally avoids encoding. Apps that need a hardware-derived tier should subclass
///   or provide a custom ``ModelBenchmarkRunner`` implementation.
public final class StandardBenchmarkRunner: ModelBenchmarkRunner {

    private static let benchmarkPrompt = "Explain briefly why the sky appears blue."

    private let inferenceService: InferenceService

    public init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    public func runBenchmark(for model: ModelInfo) async throws -> ModelBenchmarkResult {
        let start = ContinuousClock.now
        var tokenCount = 0

        // InferenceService is @MainActor — dispatch to it from the calling context.
        let stream = try await MainActor.run {
            try inferenceService.generate(
                messages: [(role: "user", content: Self.benchmarkPrompt)],
                maxOutputTokens: 64
            )
        }

        for try await event in stream.events {
            if case .token = event { tokenCount += 1 }
        }

        let elapsed = ContinuousClock.now - start
        let seconds: Double = {
            let components = elapsed.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }()
        let tps: Double? = seconds > 0 && tokenCount > 0 ? Double(tokenCount) / seconds : nil

        let tier = ModelCapabilityTier.estimate(from: model)
        return ModelBenchmarkResult(tier: tier, tokensPerSecond: tps, measuredAt: Date())
    }
}
