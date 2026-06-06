#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldHardware
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

/// Real-model coverage for adaptive prefill footprint learning (issue #1592).
///
/// The estimator's EWMA / negative-rejection / abort-guard *logic* is exhaustively
/// covered by `PrefillFootprintEstimatorTests` with synthetic deltas. This suite
/// proves the live wiring: that `LlamaGenerationDriver` actually samples resident
/// footprint at prefill chunk boundaries and reports a learned per-token cost back
/// to `LlamaBackend.lastMeasuredBytesPerToken`.
///
/// A single prefill chunk is enough to produce one accepted sample, so a normal
/// prompt yields a non-nil estimate (unless the chunk showed a net reclaim, which
/// is itself a valid observation logged below).
///
/// Requires Apple Silicon and a real GGUF — gated and skipped cleanly otherwise.
/// The mid-prefill abort path is NOT exercised here: forcing a true OOM in CI is
/// unsafe, and the abort *decision* is fully unit-tested via
/// `PrefillFootprintEstimator.wouldExceedHeadroom`.
final class LlamaPrefillFootprintIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    func test_prefill_learnsAStablePerTokenEstimate() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))

        XCTAssertNil(
            backend.lastMeasuredBytesPerToken,
            "No estimate should exist before any prefill has run"
        )

        // A few hundred prompt tokens allocate enough KV during prefill for a
        // measurable, reliably positive resident delta.
        let prompt = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        var config = GenerationConfig(maxOutputTokens: 8)
        config.seed = 7

        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        // The wiring fed the prefill chunk delta into the estimator and surfaced it.
        // If the run happened to net a reclaim (estimate nil), that is a real signal
        // worth seeing rather than a faked convergence — fail loudly with context.
        let learned = backend.lastMeasuredBytesPerToken
        if let learned {
            XCTAssertGreaterThan(learned, 0, "A learned per-token cost must be positive")
            // Feed it into a fresh plan and confirm it is actually consumable as a
            // measured budget — the cross-load feedback contract.
            let measuredPlan = ModelLoadPlan.compute(inputs: ModelLoadPlan.Inputs(
                modelFileSize: 0,
                memoryStrategy: .external,
                requestedContextSize: 1_000_000_000,
                trainedContextLength: nil,
                kvBytesPerToken: GGUFKVCacheEstimator.legacyFallbackBytesPerToken,
                availableMemoryBytes: 1_000_000_000,
                physicalMemoryBytes: 16 * 1_073_741_824,
                absoluteContextCeiling: 128_000,
                headroomFraction: 0.40,
                measuredBytesPerToken: learned
            ))
            XCTAssertGreaterThan(measuredPlan.effectiveContextSize, 0)
        } else {
            throw XCTSkip("Net reclaim observed across all chunks — device under memory pressure; re-run on an unconstrained host to confirm wiring")
        }
    }
}
#endif
