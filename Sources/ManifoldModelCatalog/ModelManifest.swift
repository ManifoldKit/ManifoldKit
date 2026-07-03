import Foundation
import ManifoldHardware

/// A bitset of sampling parameters a backend's request payload accepts on
/// behalf of the loaded model.
///
/// ``ModelManifest`` carries a ``ModelManifest/supportedSamplingParameters``
/// value to drive the request-build path: when a backend serialises a
/// generation request, it consults this set to decide which fields to emit on
/// the wire. A field that is absent from the set MUST be omitted entirely
/// rather than sent with a default — many cloud providers reject unknown or
/// unsupported parameters with HTTP 400.
///
/// The set is intentionally narrower than ``GenerationParameter``. The latter
/// is a UI-facing "what knobs should we render" enum that includes
/// llama.cpp-only sampler families (DRY, XTC, Mirostat). The manifest set is
/// the request-building counterpart: which generic OpenAI-shaped parameters
/// (`seed`, `presence_penalty`, `frequency_penalty`,
/// `repeat_penalty`, `stop`) the loaded model honours.
///
/// > Note: `.logitBias` (formerly `1 << 5`) was removed in the v0.64
/// > inert-surface sweep — `GenerationConfig` never had a `logitBias` field
/// > to carry a value, so the bit was structurally incapable of affecting a
/// > request even in principle. `1 << 5` is retired, not reused, so any
/// > persisted raw values that happened to set it decode harmlessly (the bit
/// > is simply not represented by a named option anymore).
public struct SamplingParameterSet: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let temperature       = SamplingParameterSet(rawValue: 1 << 0)
    public static let topP              = SamplingParameterSet(rawValue: 1 << 1)
    public static let topK              = SamplingParameterSet(rawValue: 1 << 2)
    public static let presencePenalty   = SamplingParameterSet(rawValue: 1 << 3)
    public static let frequencyPenalty  = SamplingParameterSet(rawValue: 1 << 4)
    public static let stopSequences     = SamplingParameterSet(rawValue: 1 << 6)
    public static let repeatPenalty     = SamplingParameterSet(rawValue: 1 << 7)
}

/// Whether a model lives on-device, on a remote SaaS endpoint, or somewhere
/// on the local network.
///
/// Informational — used by tests and capability gating but not by the request
/// path.
public enum ProducerKind: String, Sendable, Equatable, Codable {
    /// Weights load locally (MLX, llama.cpp, Foundation Models).
    case local
    /// Hosted by a SaaS API (OpenAI, Anthropic, etc.).
    case cloud
    /// Reachable on the local network (Ollama, LM Studio).
    case lan
}

/// An introspectable description of the currently loaded model.
///
/// ``ModelManifest`` is the single source of truth for everything the
/// application needs to know about the model behind a backend: how big its
/// context window is, whether it emits reasoning tokens (and behind which
/// markers), whether the request path may include a `seed` field, and which
/// sampling parameters the wire layer should serialise.
///
/// The manifest is populated by the backend at ``InferenceBackend/loadModel(from:plan:)``
/// time — local backends introspect `config.json`/GGUF metadata directly,
/// LAN backends call introspection endpoints (`/api/show`), and cloud
/// backends look the model up in a vendored prefix table
/// (``CloudModelManifestTable``). When a backend cannot determine a value at
/// load time it falls back to ``ModelManifest/unknown(modelIdentifier:)`` and
/// emits a `Log.warn` so the consumer sees the degradation.
///
/// ``BackendCapabilities`` becomes a derived view of the manifest plus
/// transport-shaped flags (streaming, vision, tool-call streaming). Tests
/// assert the cross-backend invariant that `.thinkingToken` emitters report
/// `manifest.supportsThinking == true` — see
/// `BackendCapabilitiesContractTests`.
public struct ModelManifest: Sendable, Equatable, Codable {
    /// The model's true context window in tokens.
    ///
    /// Read from `text_config.max_position_embeddings` (preferred), or
    /// `max_position_embeddings` / `model_max_length` for legacy MLX configs;
    /// from `model_info.context_length` on Ollama's `/api/show`; or from a
    /// vendored prefix-table entry for cloud providers.
    public let contextWindow: Int

    /// Whether the model accepts and honours tool-call definitions in the
    /// request body.
    public let supportsTools: Bool

    /// Whether the model emits reasoning tokens that the backend's stream
    /// parser will surface as ``GenerationEvent/thinkingToken(_:)`` events.
    ///
    /// Cross-backend invariant: any backend that can emit
    /// `.thinkingToken` MUST report `supportsThinking == true`. See
    /// `BackendCapabilitiesContractTests`.
    public let supportsThinking: Bool

    /// The marker pair the backend should use when splitting reasoning
    /// tokens from visible output.
    ///
    /// `nil` means "no inline marker pair" — either because reasoning is
    /// delivered as a side channel (Anthropic `thinking_delta` blocks,
    /// OpenAI `reasoning_content` deltas, Ollama `message.thinking`) or
    /// because the model is not a thinking model. Backends that detect
    /// markers from a chat template (Llama, MLX, Ollama template scan)
    /// surface them here for the inline-fallback parser.
    public let thinkingMarkers: ThinkingMarkers?

    /// Whether the model accepts a deterministic sampling seed on the wire.
    ///
    /// OpenAI Chat Completions accepts `seed`; Anthropic Messages does not;
    /// most reasoning models (`o1`, `o3` family) reject it.
    public let supportsSeed: Bool

    /// Sampling parameters the request-building path may serialise.
    ///
    /// Fields outside this set MUST be omitted from the request body — many
    /// cloud providers reject unknown parameters with HTTP 400.
    public let supportedSamplingParameters: SamplingParameterSet

    /// Stable identifier for the model — for cloud backends this is the
    /// API model name (e.g. `"gpt-4o"`, `"claude-sonnet-4-5"`); for local
    /// backends it's the directory name or HF repo path.
    public let modelIdentifier: String

    /// Where the model runs.
    public let producerKind: ProducerKind

    public init(
        contextWindow: Int,
        supportsTools: Bool,
        supportsThinking: Bool,
        thinkingMarkers: ThinkingMarkers?,
        supportsSeed: Bool,
        supportedSamplingParameters: SamplingParameterSet,
        modelIdentifier: String,
        producerKind: ProducerKind
    ) {
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsThinking = supportsThinking
        self.thinkingMarkers = thinkingMarkers
        self.supportsSeed = supportsSeed
        self.supportedSamplingParameters = supportedSamplingParameters
        self.modelIdentifier = modelIdentifier
        self.producerKind = producerKind
    }

    /// Conservative manifest used when a backend cannot introspect the
    /// loaded model.
    ///
    /// The defaults intentionally undersell rather than oversell: 8k
    /// context window (modern minimum), no tools, no thinking, no seed,
    /// only `temperature` + `topP` sampling. A backend that returns
    /// `.unknown(...)` should emit a `Log.warn` so the consumer sees the
    /// degradation.
    public static func unknown(
        modelIdentifier: String,
        producerKind: ProducerKind = .local
    ) -> ModelManifest {
        ModelManifest(
            contextWindow: 8192,
            supportsTools: false,
            supportsThinking: false,
            thinkingMarkers: nil,
            supportsSeed: false,
            supportedSamplingParameters: [.temperature, .topP],
            modelIdentifier: modelIdentifier,
            producerKind: producerKind
        )
    }
}
