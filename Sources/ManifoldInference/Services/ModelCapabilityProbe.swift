import Foundation

/// Capabilities reported by a Hugging Face model's `config.json`.
///
/// Populated by ``ModelCapabilityProbe`` from on-disk JSON before the model
/// is handed to a backend. The probe deliberately keys off durable, format-level
/// signals (`vision_config`, `audio_config`, `max_position_embeddings`) rather
/// than enumerating known `model_type` strings, so newly-released architectures
/// are detected without a code change.
public struct ModelCapabilities: Sendable, Equatable {
    /// True when `config.json` contains a top-level `vision_config` object.
    /// An explicit JSON `null` does not count — the key must map to an object.
    public let supportsVision: Bool
    /// True when `config.json` contains a top-level `audio_config` object.
    /// An explicit JSON `null` does not count — the key must map to an object.
    public let supportsAudio: Bool
    /// First non-nil of `max_position_embeddings`, `n_ctx`,
    /// `text_config.max_position_embeddings`, or `text_config.n_ctx`.
    /// `nil` when none of those keys are present (e.g. embedding-only models).
    public let contextLength: Int?

    public init(
        supportsVision: Bool,
        supportsAudio: Bool,
        contextLength: Int?
    ) {
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.contextLength = contextLength
    }
}

/// Errors raised by ``ModelCapabilityProbe``.
public enum ModelCapabilityProbeError: LocalizedError, Equatable {
    case configNotFound(URL)
    case invalidConfigJSON(URL)

    public var errorDescription: String? {
        switch self {
        case let .configNotFound(url):
            return "config.json not found at \(url.path)"
        case let .invalidConfigJSON(url):
            return "config.json at \(url.path) is not a JSON object"
        }
    }
}

/// Reads a downloaded HF model directory and reports vision/audio capability
/// plus context length without loading any weights.
///
/// Why this exists: backends (MLX in particular) need to choose between
/// `LLMModelFactory` and `VLMModelFactory` before instantiating the model,
/// and the UI wants to gate "attach image" affordances per-model. SwiftLM
/// solves the routing problem with a hardcoded `model_type` allowlist that
/// rots every time a new VLM ships; this probe instead inspects the durable
/// JSON shape — `vision_config` / `audio_config` are emitted by the
/// transformers library for any multimodal architecture, so detection
/// extends to new models for free.
public enum ModelCapabilityProbe {
    /// Probes the model directory at `modelDirectory` and returns its capabilities.
    ///
    /// - Parameter modelDirectory: Directory containing a Hugging Face snapshot.
    ///   Must include `config.json`. `preprocessor_config.json`, when present,
    ///   is reserved for future multimodal-detail extraction and is not read today.
    /// - Throws: ``ModelCapabilityProbeError`` if `config.json` is missing or malformed.
    public static func probe(modelDirectory: URL) throws -> ModelCapabilities {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ModelCapabilityProbeError.configNotFound(configURL)
        }

        let configData = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ModelCapabilityProbeError.invalidConfigJSON(configURL)
        }

        // Note: `preprocessor_config.json` lives alongside `config.json` for
        // multimodal models and will be consumed by future revisions of this
        // probe (e.g. to surface image-size or audio sample-rate hints). It is
        // intentionally not read here — config.json's vision_config /
        // audio_config keys are authoritative for the flags we expose today,
        // and parsing a second file we don't use would just be noise.

        // Use `is [String: Any]` rather than `!= nil`: JSONSerialization
        // turns an explicit `"vision_config": null` into NSNull, which
        // satisfies `!= nil` and would falsely report vision support. The
        // transformers library only emits these keys as objects when the
        // architecture actually has that modality, so requiring an object
        // is both faithful to the format and robust to null sentinels.
        let supportsVision = config["vision_config"] is [String: Any]
        let supportsAudio = config["audio_config"] is [String: Any]
        // Some VLMs (e.g. PaliGemma, LLaVA-NeXT) nest the language config
        // under `text_config` and only expose `max_position_embeddings`
        // there. Fall back to that nested key before giving up so the
        // probe surfaces a context length for the common multimodal case.
        let textConfig = config["text_config"] as? [String: Any]
        let contextLength = (config["max_position_embeddings"] as? Int)
            ?? (config["n_ctx"] as? Int)
            ?? (textConfig?["max_position_embeddings"] as? Int)
            ?? (textConfig?["n_ctx"] as? Int)

        return ModelCapabilities(
            supportsVision: supportsVision,
            supportsAudio: supportsAudio,
            contextLength: contextLength
        )
    }
}
