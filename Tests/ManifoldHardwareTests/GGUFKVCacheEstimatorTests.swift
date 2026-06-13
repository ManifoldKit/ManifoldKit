import XCTest
@testable import ManifoldHardware
@_spi(BackendInternals) import ManifoldHardware

final class GGUFKVCacheEstimatorTests: XCTestCase {

    func test_estimateBytesPerToken_llama7BGQAMatchesExpectedMath() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 131_072)
    }

    func test_estimateBytesPerToken_explicitKeyAndValueLengthsOverrideEmbeddingHeuristic() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 28,
            embeddingLength: 3072,
            attentionHeadCount: 24,
            attentionHeadCountKV: 6,
            attentionKeyLength: 96,
            attentionValueLength: 128
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 75_264)
    }

    func test_estimateBytesPerToken_returnsNilWhenMetadataIsIncomplete() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            attentionHeadCountKV: 8
        )

        XCTAssertNil(GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters))
    }

    // MARK: - Architecture matrix

    /// Llama-3 8B: GQA 8:1 (`attentionHeadCountKV < attentionHeadCount`).
    /// Ref: https://huggingface.co/meta-llama/Meta-Llama-3-8B/blob/main/config.json
    /// (num_hidden_layers=32, hidden_size=4096, num_attention_heads=32,
    /// num_key_value_heads=8). This is the dominant modern architecture and
    /// the canonical case the GQA divisor matters for — a regression here
    /// silently over- or under-estimates KV for Llama-3 and most of its
    /// derivatives.
    ///
    /// Hand math (fp16 = 2 B/element):
    /// ```
    /// headDim       = embedding / heads   = 4096 / 32 = 128
    /// keyWidth      = headDim * kvHeads   = 128 * 8   = 1024
    /// valueWidth    = same (no explicit)  = 1024
    /// bytesPerToken = blocks * (K + V) * element
    ///               = 32 * 2048 * 2       = 131 072
    /// ```
    func test_estimateBytesPerToken_llama3_8B_GQA_matchesHandCalculation() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 131_072)
    }

    /// Llama-2 7B shape: MHA (`attentionHeadCountKV == attentionHeadCount`).
    /// Llama-2 7B uses 32 blocks, 4096 embedding, 32 attention heads, 32 KV heads
    /// (MHA) — ref: https://huggingface.co/meta-llama/Llama-2-7b-hf/blob/main/config.json
    /// (num_hidden_layers=32, hidden_size=4096, num_attention_heads=32, no
    /// num_key_value_heads → MHA with KV == Q). Catches a regression where
    /// the GQA divisor path accidentally treats every model as GQA:8.
    ///
    /// NOTE: Mistral 7B looks similar but uses GQA 4:1 (num_key_value_heads=8);
    /// don't conflate the two. The MHA case here is specifically Llama-2.
    ///
    /// Hand math: 32 * (4096 + 4096) * 2 = 524 288 B/token.
    func test_estimateBytesPerToken_llama2_7B_MHA_matchesHandCalculation() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 32
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 524_288)
    }

    /// Synthetic asymmetric K/V: explicit `attentionKeyLength != attentionValueLength`.
    /// No shipped Qwen2/Llama GGUFs we've seen use K ≠ V, but the GGUF spec allows it
    /// (`.attention.key_length` and `.attention.value_length` are independent keys) and
    /// Multi-head Latent Attention variants (DeepSeek-V2) and future architectures
    /// may. A naive estimator that assumed K == V would silently under-estimate when
    /// value dim is larger, or over-estimate when smaller.
    ///
    /// Fixture uses exaggerated asymmetry (128 vs 64) so the K-path and V-path
    /// cannot collapse into the same value and silently pass the test.
    ///
    /// Hand math (28 blocks, 4 KV heads, fp16):
    /// ```
    /// keyWidth   = 128 * 4 = 512
    /// valueWidth =  64 * 4 = 256
    /// total      = 28 * (512 + 256) * 2 = 43 008 B/token
    /// ```
    func test_estimateBytesPerToken_asymmetricKVDims_matchesHandCalculation() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 28,
            embeddingLength: 3584,           // unused when explicit lengths are present
            attentionHeadCount: 28,          // unused when explicit lengths are present
            attentionHeadCountKV: 4,
            attentionKeyLength: 128,
            attentionValueLength: 64
        )

        let estimate = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters)

        XCTAssertEqual(estimate, 43_008)
    }

    // MARK: - Quantization assumption

    /// Pin the fp16 (`defaultBytesPerElement == 2`) assumption that the whole
    /// estimator rests on. If llama.cpp ever adds Q4/Q8 KV cache support and a
    /// downstream change starts passing `bytesPerElement < 2`, the plan will
    /// suddenly estimate half as much memory — silently allowing OOM-bound
    /// loads that previously warned. This test is the alarm.
    ///
    /// Asserts two invariants:
    /// 1. The default constant is exactly 2 (fp16).
    /// 2. Halving the byte width halves the estimate — so callers who
    ///    customise `bytesPerElement` get a linear, predictable change.
    func test_defaultBytesPerElement_isFP16_andScalesLinearly() {
        XCTAssertEqual(GGUFKVCacheEstimator.defaultBytesPerElement, 2,
                       "defaultBytesPerElement must stay fp16 (2 bytes) until Q4/Q8 KV is supported")

        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8
        )

        let fp16 = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters, bytesPerElement: 2)
        let q8 = GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters, bytesPerElement: 1)

        XCTAssertEqual(fp16, 131_072)
        XCTAssertEqual(q8, 65_536, "Halving bytesPerElement must halve the estimate")
    }

    /// `bytesPerElement == 0` must be rejected — otherwise the estimator would
    /// return 0 and `ModelLoadPlan` would see "KV costs nothing" and allow any
    /// context. This is a defensive contract with the estimator's callers.
    func test_bytesPerElementZero_returnsNil() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8
        )
        XCTAssertNil(
            GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters, bytesPerElement: 0)
        )
    }

    // MARK: - Overflow hardening

    /// A malformed or crafted GGUF can supply enormous block/width values whose
    /// `block × (K+V)` product exceeds `UInt64.max`. An unchecked multiply would
    /// wrap to a tiny per-token estimate, ModelLoadPlan would see "KV is cheap"
    /// and `.allow`, then the load OOMs at inference. The estimator must instead
    /// return `nil` so the caller's conservative legacy-fallback path engages.
    ///
    /// Uses explicit key/value lengths so `gqaWidth` returns
    /// `explicitHeadLength * kvHeadCount` directly. With kvHeadCount == 1,
    /// keyWidth == valueWidth == 4_000_000_000 → widthSum == 8_000_000_000.
    /// 5_000_000_000 × 8_000_000_000 ≈ 4e19 > UInt64.max (~1.8e19) → overflow on
    /// the block × width multiply.
    func test_estimateBytesPerToken_blockTimesWidthOverflow_returnsNil() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 5_000_000_000,
            attentionHeadCount: 1,
            attentionHeadCountKV: 1,
            attentionKeyLength: 4_000_000_000,
            attentionValueLength: 4_000_000_000
        )

        XCTAssertNil(
            GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters),
            "block × (K+V) overflowing UInt64 must yield nil, not a wrapped tiny estimate"
        )
    }

    /// Overflow on the *second* multiply (`perTokenElements × bytesPerElement`).
    /// Here block × width fits in UInt64, but scaling by a large bytes-per-element
    /// pushes it past the ceiling. Both multiply guards must hold, not just the
    /// first. blockCount 4_000_000_000 × widthSum 4_000_000_000 == 1.6e19 (fits),
    /// then × 100 overflows.
    func test_estimateBytesPerToken_bytesPerElementScaleOverflow_returnsNil() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 4_000_000_000,
            attentionHeadCount: 1,
            attentionHeadCountKV: 1,
            attentionKeyLength: 2_000_000_000,
            attentionValueLength: 2_000_000_000
        )

        XCTAssertNil(
            GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters, bytesPerElement: 100),
            "scaling a near-ceiling product by bytesPerElement must guard overflow and yield nil"
        )
    }

    /// `gqaWidth`'s Int multiply (`explicitHeadLength * kvHeadCount`) is itself
    /// reachable with crafted values and a trapping `*` would crash the process
    /// before the UInt64 guards run. A huge head length paired with a huge KV
    /// head count must return nil, not abort. (5e9 × 5e9 ≈ 2.5e19 > Int.max.)
    func test_estimateBytesPerToken_gqaWidthIntOverflow_returnsNil() {
        let parameters = GGUFKVCacheParameters(
            blockCount: 1,
            attentionHeadCount: 5_000_000_000,
            attentionHeadCountKV: 5_000_000_000,
            attentionKeyLength: 5_000_000_000,
            attentionValueLength: 5_000_000_000
        )

        XCTAssertNil(
            GGUFKVCacheEstimator.estimateBytesPerToken(from: parameters),
            "gqaWidth Int multiply overflowing must yield nil, not trap the process"
        )
    }
}
