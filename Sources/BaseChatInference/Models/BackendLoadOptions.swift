import Foundation

/// Tuning knobs that affect how a local backend allocates KV cache, attention
/// kernels, and prefill batches at load time.
///
/// Distinct from ``GenerationConfig`` (per-message) because llama.cpp wires
/// these into `ctxParams` at context-creation time — they cannot be changed
/// per-generation without rebuilding the context. MLX exposes some of the
/// same knobs per-generation; BCK normalises them to load-time so the API
/// shape matches across backends.
///
/// Apply via the backend's `setLoadOptions(_:)` method **before** calling
/// `loadModel(from:plan:)`. Changing options after load takes effect on the
/// next load. Backends that do not honour a particular field (e.g. MLX has no
/// `flashAttention` knob — it is always on in mlx-swift's SDPA) silently
/// ignore that field.
///
/// Defaults preserve historical behaviour bit-for-bit. See issue #1017 for
/// the planned default flips after the opt-in surface has soaked through one
/// release.
public struct BackendLoadOptions: Sendable, Codable, Equatable {

    /// KV cache element type.
    ///
    /// The KV cache stores per-token attention key/value tensors. Quantizing
    /// it cuts memory roughly proportionally and is independent of the
    /// model's weight quantization (Q4 weights + ``q8`` KV is the standard
    /// recipe in mlx-lm Python and llama.cpp).
    public enum KVCacheQuantization: String, Sendable, Codable, CaseIterable {
        /// Full-precision FP16. Library default. Highest quality, highest memory.
        case f16
        /// 8-bit quantized. ~50% memory reduction at effectively zero quality
        /// loss. Maps to llama.cpp's `GGML_TYPE_Q8_0` and mlx-swift-lm's
        /// `kvBits = 8`. Recommended once the opt-in surface soaks (#1017).
        case q8
        /// 4-bit quantized. ~75% memory reduction with measurable quality
        /// loss, especially on GQA/MQA models. Use only when memory pressure
        /// forces it. Maps to `GGML_TYPE_Q4_0` and `kvBits = 4`.
        case q4
    }

    /// KV cache element type. See ``KVCacheQuantization``.
    public var kvCacheQuantization: KVCacheQuantization

    /// Enable Flash Attention. Llama-only — MLX's SDPA path is always
    /// flash-attention-shaped. Free perf on Metal at long context.
    ///
    /// Always disabled under `targetEnvironment(simulator)` regardless of
    /// this value: simulator Metal does not reliably support FA kernels.
    public var flashAttention: Bool

    /// Number of tokens fed to the model per prefill step.
    ///
    /// `nil` lets each backend use its library default (llama.cpp `n_batch`
    /// 2048; mlx-swift-lm `prefillStepSize` 512). Larger values reduce TTFT
    /// on long prompts at the cost of a memory spike during prefill.
    public var prefillBatchSize: Int?

    public init(
        kvCacheQuantization: KVCacheQuantization = .f16,
        flashAttention: Bool = false,
        prefillBatchSize: Int? = nil
    ) {
        self.kvCacheQuantization = kvCacheQuantization
        self.flashAttention = flashAttention
        self.prefillBatchSize = prefillBatchSize
    }

    /// Library-default options. Behaviour matches BCK pre-PR (no quantized KV,
    /// no Flash Attention, library-default prefill batch).
    public static let `default` = BackendLoadOptions()

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kvCacheQuantization
        case flashAttention
        case prefillBatchSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Forward-compat: every field decodes to its library-default when absent
        // so older payloads written before this type existed decode cleanly.
        kvCacheQuantization =
            (try c.decodeIfPresent(KVCacheQuantization.self, forKey: .kvCacheQuantization)) ?? .f16
        flashAttention = (try c.decodeIfPresent(Bool.self, forKey: .flashAttention)) ?? false
        prefillBatchSize = try c.decodeIfPresent(Int.self, forKey: .prefillBatchSize)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kvCacheQuantization, forKey: .kvCacheQuantization)
        try c.encode(flashAttention, forKey: .flashAttention)
        try c.encodeIfPresent(prefillBatchSize, forKey: .prefillBatchSize)
    }
}
