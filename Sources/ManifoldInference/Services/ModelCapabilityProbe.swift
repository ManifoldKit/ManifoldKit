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
    /// True when the checkpoint advertises itself as a code-specialised model.
    /// Inferred conservatively from durable signals: HF model-card front-matter
    /// `pipeline_tag` / `tags` (`README.md`), `tags` arrays in `config.json`,
    /// or an `architectures` entry whose name contains "code"/"coder". Display
    /// names are deliberately not consulted — they drift.
    public let supportsCodeGeneration: Bool
    /// True when the checkpoint advertises ≥ 2 supported natural languages.
    /// Inferred from the HF model-card front-matter `language` field
    /// (`README.md`) when it is a list of two or more entries, or from a
    /// `language` array in `config.json` of the same shape. Single-language
    /// declarations do not count.
    public let supportsMultilingual: Bool
    /// First non-nil of `max_position_embeddings`, `n_ctx`,
    /// `text_config.max_position_embeddings`, or `text_config.n_ctx`.
    /// `nil` when none of those keys are present (e.g. embedding-only models).
    public let contextLength: Int?

    public init(
        supportsVision: Bool,
        supportsAudio: Bool,
        supportsCodeGeneration: Bool = false,
        supportsMultilingual: Bool = false,
        contextLength: Int?
    ) {
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.supportsCodeGeneration = supportsCodeGeneration
        self.supportsMultilingual = supportsMultilingual
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

        // README.md front-matter is the canonical place for HF-side metadata
        // (`language`, `tags`, `pipeline_tag`). config.json sometimes mirrors
        // a subset of these as extra fields. Both feed the code/multilingual
        // inference; either source being present is sufficient. Missing
        // README is normal (some snapshots strip it) so we treat it as the
        // absence of a positive signal rather than an error.
        let cardMetadata = readModelCardMetadata(in: modelDirectory)

        let supportsCodeGeneration = inferCodeGeneration(
            config: config,
            card: cardMetadata
        )
        let supportsMultilingual = inferMultilingual(
            config: config,
            card: cardMetadata
        )

        return ModelCapabilities(
            supportsVision: supportsVision,
            supportsAudio: supportsAudio,
            supportsCodeGeneration: supportsCodeGeneration,
            supportsMultilingual: supportsMultilingual,
            contextLength: contextLength
        )
    }

    // MARK: - Code / multilingual heuristics

    /// Tags / pipeline / language extracted from `README.md` YAML front-matter.
    /// Empty when the README is missing, has no front-matter, or fails to
    /// parse — the probe deliberately under-reports rather than guessing.
    private struct ModelCardMetadata {
        var tags: [String] = []
        var pipelineTag: String?
        var languages: [String] = []
    }

    private static func readModelCardMetadata(in directory: URL) -> ModelCardMetadata {
        let readmeURL = directory.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readmeURL.path),
              let data = try? Data(contentsOf: readmeURL),
              let contents = String(data: data, encoding: .utf8)
        else {
            return ModelCardMetadata()
        }
        return parseFrontMatter(contents)
    }

    /// Hand-rolled YAML front-matter parser limited to the three fields we
    /// consult. Full YAML is overkill — HF cards stick to a tight subset
    /// (`key: value` and `key:\n  - item` block lists) and a real YAML
    /// dependency would pull a parser into a module that otherwise has none.
    private static func parseFrontMatter(_ contents: String) -> ModelCardMetadata {
        var metadata = ModelCardMetadata()
        // Front-matter must be the literal first bytes of the file, fenced by
        // `---` lines. Anything else (BOM, blank line) means no front-matter.
        guard contents.hasPrefix("---") else { return metadata }
        let afterOpen = contents.dropFirst(3)
        guard let closeRange = afterOpen.range(of: "\n---") else { return metadata }
        let body = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and YAML comments.
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            // Top-level keys are unindented; nested keys start with whitespace.
            // We only care about top-level here.
            guard line.first.map({ !$0.isWhitespace }) == true,
                  let colonIndex = line.firstIndex(of: ":")
            else {
                index += 1
                continue
            }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "tags":
                let (values, consumed) = collectListValue(inline: rawValue, lines: lines, after: index)
                metadata.tags = values
                index += consumed
            case "language", "languages":
                let (values, consumed) = collectListValue(inline: rawValue, lines: lines, after: index)
                metadata.languages = values
                index += consumed
            case "pipeline_tag":
                metadata.pipelineTag = unquote(rawValue)
                index += 1
            default:
                index += 1
            }
        }
        return metadata
    }

    /// Resolves a YAML scalar/inline-list/block-list value into a flat string
    /// array. Returns the number of lines consumed (≥ 1) so the caller can
    /// advance past any block-list entries.
    private static func collectListValue(
        inline: String,
        lines: [String],
        after startIndex: Int
    ) -> ([String], Int) {
        // Inline scalar: `tags: foo`
        if !inline.isEmpty, !inline.hasPrefix("[") {
            return ([unquote(inline)], 1)
        }
        // Inline flow-style list: `tags: [foo, bar]`
        if inline.hasPrefix("[") {
            let inner = inline.dropFirst().dropLast(inline.hasSuffix("]") ? 1 : 0)
            let items = inner.split(separator: ",").map {
                unquote($0.trimmingCharacters(in: .whitespaces))
            }
            return (items.filter { !$0.isEmpty }, 1)
        }
        // Block list: subsequent indented `- item` lines.
        var items: [String] = []
        var consumed = 1
        var cursor = startIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                cursor += 1
                consumed += 1
                continue
            }
            // A non-indented non-list line ends the block.
            guard line.first?.isWhitespace == true, trimmed.hasPrefix("- ") else {
                break
            }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            items.append(unquote(value))
            cursor += 1
            consumed += 1
        }
        return (items, consumed)
    }

    private static func unquote(_ value: String) -> String {
        var v = value
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func inferCodeGeneration(
        config: [String: Any],
        card: ModelCardMetadata
    ) -> Bool {
        // README front-matter is the primary signal: `pipeline_tag` or a `tags`
        // entry containing "code". HF's own taxonomy uses kebab-case
        // ("text-generation", "code-generation") and lowercases tag values.
        if let pipeline = card.pipelineTag?.lowercased(),
           pipeline.contains("code") {
            return true
        }
        if card.tags.contains(where: { $0.lowercased().contains("code") }) {
            return true
        }
        // Fallback: some configs duplicate `tags` as a JSON array. Same rule.
        if let configTags = config["tags"] as? [String],
           configTags.contains(where: { $0.lowercased().contains("code") }) {
            return true
        }
        // Last resort: `architectures` is a JSON array of class names like
        // `["CodeLlamaForCausalLM"]`. Most coders reuse the base arch name
        // (CodeLlama → LlamaForCausalLM) so this only fires for the handful
        // that ship a distinct class. Conservative by design.
        if let archs = config["architectures"] as? [String] {
            // Substring "coder" matches both "...CoderForCausalLM" (positive)
            // and "...DecoderForCausalLM" (negative). Strip "decoder" before
            // testing so the false positive is impossible without re-implementing
            // a regex engine for one needle.
            let stripsDecoder: (String) -> String = { $0.lowercased().replacingOccurrences(of: "decoder", with: "") }
            if archs.contains(where: { stripsDecoder($0).contains("coder") }) {
                return true
            }
        }
        return false
    }

    private static func inferMultilingual(
        config: [String: Any],
        card: ModelCardMetadata
    ) -> Bool {
        // ≥ 2 distinct language codes in the README front-matter is the
        // canonical HF declaration. We dedupe case-insensitively because
        // some cards list both "en" and "English".
        let cardLanguages = Set(card.languages.map { $0.lowercased() })
        if cardLanguages.count >= 2 {
            return true
        }
        // Mirror the same rule for an optional `language` array on config.json
        // (rare, but some checkpoints include it).
        if let configLanguages = config["language"] as? [String] {
            let set = Set(configLanguages.map { $0.lowercased() })
            if set.count >= 2 {
                return true
            }
        }
        // An explicit `multilingual` tag is a final, unambiguous signal.
        if card.tags.contains(where: { $0.lowercased() == "multilingual" }) {
            return true
        }
        return false
    }
}
