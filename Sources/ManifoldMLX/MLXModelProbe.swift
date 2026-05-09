#if MLX
import Foundation
import ManifoldInference

/// Probes MLX model directories for architecture, factory routing, and manifest metadata.
enum MLXModelProbe {
    /// Canonical `model_type` values that `mlx-swift-lm`'s `LLMTypeRegistry.shared`
    /// can serve as chat/instruct LMs. Anything outside this set (or the
    /// VLM-specific set below) — CLIP, SigLIP, Whisper, BERT embeddings, etc. —
    /// is refused at load time via `InferenceError.unsupportedModelArchitecture`.
    ///
    /// Sourced from `LLMTypeRegistry.shared` in mlx-swift-lm
    /// (`Libraries/MLXLLM/LLMModelFactory.swift`). When mlx-swift-lm adds a new
    /// LM architecture, update this list to match so the preflight doesn't reject
    /// a freshly supported model.
    static let supportedLMArchitectures: Set<String> = [
        "mistral", "llama", "phi", "phi3", "phimoe",
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        "minicpm", "starcoder2", "cohere", "openelm", "internlm2",
        "deepseek_v3", "granite", "granitemoehybrid",
        "mimo", "mimo_v2_flash", "minimax",
        "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3",
        "ernie4_5", "lfm2", "lfm2_moe",
        "baichuan_m1", "exaone4", "gpt_oss",
        "lille-130m", "olmoe", "olmo2", "olmo3",
        "bailing_moe", "nanochat", "nemotron_h",
        "afmoe", "jamba_3b", "mistral3", "apertus",
    ]

    static let supportedVLMArchitectures: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "qwen3_5", "qwen3_5_moe", "idefics3", "gemma3", "gemma4",
        "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3",
        "lfm2_vl", "lfm2-vl", "glm_ocr",
    ]

    private static let normalizedSupportedArchitectures: Set<String> =
        Set((supportedLMArchitectures.union(supportedVLMArchitectures)).map(normalizeArchitectureKey))

    static func normalizeArchitectureKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Reads `config.json` at `url` and throws
    /// `InferenceError.unsupportedModelArchitecture` if the declared `model_type`
    /// is not a chat/instruct LM. If `config.json` is missing or unreadable the
    /// check is a no-op — mlx-swift-lm's own load path will then surface the
    /// real error (missing weights, malformed directory, etc.).
    static func validateArchitecture(at url: URL) throws {
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / malformed config.json: let the MLX load path produce the
            // real diagnostic rather than masking it with a false architecture error.
            return
        }

        let modelType = (json["model_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedModelType = normalizeArchitectureKey(modelType)
        if !normalizedModelType.isEmpty,
           normalizedSupportedArchitectures.contains(normalizedModelType) {
            return
        }

        // Some HF repos omit model_type but include an `architectures` array
        // (e.g. ["LlamaForCausalLM"]). Accept the load if any entry's snake_case
        // prefix matches the allowlist — this keeps older snapshots working.
        if let archs = json["architectures"] as? [String] {
            for arch in archs {
                let normalized = normalizeArchitectureKey(arch)
                if Self.normalizedSupportedArchitectures.contains(where: { normalized.hasPrefix($0) }) {
                    return
                }
            }
        }

        let reported = modelType.isEmpty ? (json["architectures"] as? [String])?.joined(separator: ",") ?? "unknown" : modelType
        throw InferenceError.unsupportedModelArchitecture(reported)
    }

    /// Returns `true` when the model at `url` must load through the VLM factory.
    ///
    /// This covers both explicit multimodal models (`vision_config`) and the
    /// Gemma 4 MoE path that only exists behind `VLMModelFactory` today.
    ///
    /// Falls back to `false` (LLM factory) when config.json is missing/unreadable —
    /// matches the same conservative default used by `validateArchitecture`. Dense
    /// Gemma 4 models intentionally stay on the LLM factory so we don't pay the
    /// memory cost of resident vision-tower weights.
    static func requiresVLMFactory(at url: URL) -> Bool {
        requiresVLMFactory(at: url, precomputedCapabilities: nil)
    }

    /// Variant that accepts pre-computed capabilities to avoid re-reading
    /// `config.json` when the caller already ran ``ModelCapabilityProbe``.
    static func requiresVLMFactory(
        at url: URL,
        precomputedCapabilities capabilities: ModelCapabilities?
    ) -> Bool {
        // Fast path: vision was already detected by the caller's probe run.
        if let capabilities {
            if capabilities.supportsVision { return true }
        } else {
            do {
                if try ModelCapabilityProbe.probe(modelDirectory: url).supportsVision {
                    return true
                }
            } catch {
                Log.inference.info(
                    "MLX capability probe failed for \(url.lastPathComponent, privacy: .public); falling back to config.json routing (\(error.localizedDescription, privacy: .public))"
                )
            }
        }
        // MoE fallback: Gemma 4 26B ships `text_config.enable_moe_block = true`
        // and its MoE decoder only exists in the VLM factory today.
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let textConfig = json["text_config"] as? [String: Any],
           textConfig["enable_moe_block"] as? Bool == true {
            return true
        }
        return false
    }

    /// Reads `tokenizer_config.json` inside `url` and returns the best-matching
    /// thinking-marker preset for the chat template it declares.
    ///
    /// Best-effort: a missing or unreadable `tokenizer_config.json`, or one
    /// without a `chat_template` field, returns `nil`. The MLX tokenizer object
    /// in `mlx-swift-lm` exposes the chat template through Hugging Face's
    /// swift-transformers, but reaching it requires opening a `ModelContainer`
    /// session — reading the on-disk JSON directly is faster and avoids
    /// tying up the GPU during the load.
    ///
    /// - Parameter url: The model directory URL (same one passed to
    ///   `MLXBackend.loadModel(from:plan:)`).
    /// - Returns: The auto-detected ``ThinkingMarkers`` or `nil` if no known
    ///   marker pair is present in the template.
    static func detectThinkingMarkers(at url: URL) -> ThinkingMarkers? {
        let configURL = url.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / unreadable tokenizer_config.json is expected for some
            // model layouts (older snapshots, partial downloads). Don't warn —
            // callers explicitly opt out of thinking parsing when this is nil.
            return nil
        }

        // `chat_template` is a single string for most HF tokenizers, but a
        // small number of repos ship an array of `{name, template}` entries
        // (multi-template configs). When that happens, sniff the first entry
        // whose name is `default` (or the first entry overall).
        let templateString: String? = {
            if let s = json["chat_template"] as? String { return s }
            if let arr = json["chat_template"] as? [[String: Any]] {
                if let def = arr.first(where: { ($0["name"] as? String)?.lowercased() == "default" }),
                   let s = def["template"] as? String {
                    return s
                }
                if let s = arr.first?["template"] as? String { return s }
            }
            return nil
        }()
        guard let template = templateString else { return nil }
        return ThinkingMarkers.fromChatTemplate(template)
    }

    /// Produces a ``ModelManifest`` from a freshly-loaded MLX model directory.
    ///
    /// Reads `config.json` to extract the true context window:
    /// `text_config.max_position_embeddings` (preferred for VLM/MoE configs),
    /// `max_position_embeddings`, or `model_max_length` as a final fallback.
    /// Combines with the chat-template-detected ``ThinkingMarkers`` and the
    /// vision-capability flag to populate the manifest.
    ///
    /// Falls back to ``ModelManifest/unknown(modelIdentifier:producerKind:)``
    /// (with a `Log.warn`) when `config.json` is missing or carries no
    /// position-embedding hint. The conservative default (8k) keeps prompts
    /// shorter than necessary on misconfigured snapshots, which is safer than
    /// over-trimming or over-feeding the model.
    static func produceManifest(
        at url: URL,
        detectedThinkingMarkers: ThinkingMarkers?,
        supportsVision: Bool
    ) -> ModelManifest {
        let modelIdentifier = url.lastPathComponent
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.inference.warning(
                "MLX manifest probe: config.json missing or unreadable for \(modelIdentifier, privacy: .public); falling back to ModelManifest.unknown"
            )
            return .unknown(modelIdentifier: modelIdentifier, producerKind: .local)
        }

        let contextWindow = extractContextWindow(from: json)
            ?? {
                Log.inference.warning(
                    "MLX manifest probe: no max_position_embeddings / model_max_length found for \(modelIdentifier, privacy: .public); falling back to 8192"
                )
                return 8192
            }()

        return ModelManifest(
            contextWindow: contextWindow,
            supportsTools: true,
            supportsThinking: detectedThinkingMarkers != nil,
            thinkingMarkers: detectedThinkingMarkers,
            supportsSeed: true,
            supportedSamplingParameters: [
                .temperature, .topP, .topK, .repeatPenalty,
                .presencePenalty, .frequencyPenalty,
            ],
            modelIdentifier: modelIdentifier,
            producerKind: .local
        )
    }

    /// Pulls the model's max position embedding count out of an MLX
    /// `config.json` payload. Returns `nil` when no recognised key is present.
    static func extractContextWindow(from json: [String: Any]) -> Int? {
        // Modern multi-modal configs nest the text encoder fields under
        // `text_config`. Prefer that over the top-level keys when present.
        if let textConfig = json["text_config"] as? [String: Any],
           let value = positiveInt(from: textConfig["max_position_embeddings"]) {
            return value
        }
        if let value = positiveInt(from: json["max_position_embeddings"]) {
            return value
        }
        if let value = positiveInt(from: json["model_max_length"]) {
            return value
        }
        return nil
    }

    static func positiveInt(from value: Any?) -> Int? {
        if let int = value as? Int, int > 0 { return int }
        if let int64 = value as? Int64, int64 > 0 { return Int(int64) }
        if let double = value as? Double, double > 0 { return Int(double) }
        if let str = value as? String, let parsed = Int(str), parsed > 0 { return parsed }
        return nil
    }
}
#endif
