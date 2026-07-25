/// Centralized, testable capability gates for image-input support.
///
/// The helpers live in `ManifoldInference` (not in any trait-gated backend
/// target) so CI can exercise the declarations with default traits disabled
/// and so all four backend families (`ManifoldMLX`, `ManifoldLlama`,
/// `ManifoldFoundation`, `ManifoldCloud`) share a single source of truth.
/// Returning `true` means the backend has both a model family known to
/// accept images and an implemented request/generation path that preserves
/// `MessagePart.image(data:mimeType:placeholderHash:)` payloads.
public enum BackendVisionCapability {
    /// Whether a llama.cpp (GGUF) backend should advertise image-input support.
    ///
    /// Both halves are required — mirrors the `MultimodalProjectorConfigurable`
    /// contract: a staged mmproj URL alone must not yield `true` unless the
    /// engine can actually turn `MessagePart.image` into embeddings
    /// (e.g. vendored llama.cpp with `mtmd`/`clip` wired). Callers in
    /// `ManifoldLlama` probe both and pass the results here; a constant
    /// `false` previously made vision structurally unreachable even after the
    /// companion implemented embedding (#2381).
    public static func llamaSupportsImageInput(
        projectorStaged: Bool,
        engineSupportsImageEmbedding: Bool
    ) -> Bool {
        projectorStaged && engineSupportsImageEmbedding
    }

    public static func mlxSupportsImageInput(probedCapabilities: ModelCapabilities?) -> Bool {
        probedCapabilities?.supportsVision ?? false
    }

    /// Ollama advertises image-input support per-model via its `/api/show`
    /// `capabilities: ["vision", ...]` list (qwen2.5vl, moondream, llava …).
    /// `OllamaBackend` probes that flag at load time; pass it here. Mirrors
    /// ``mlxSupportsImageInput(probedCapabilities:)`` — image-input support is
    /// model-driven, not a fixed family constant. `false` when the model is
    /// text-only or hasn't been probed yet.
    public static func ollamaSupportsImageInput(probedVision: Bool) -> Bool {
        probedVision
    }

    public static func openAIChatCompletionsSupportsImageInput(modelName: String) -> Bool {
        let lowered = modelName.lowercased()
        if OpenAIChatCompletionsVisionModels.substringTokens.contains(where: lowered.contains) {
            return true
        }
        for prefix in OpenAIChatCompletionsVisionModels.anchoredPrefixes {
            if matchesAnchoredPrefix(lowered, prefix: prefix) {
                return true
            }
        }
        return false
    }

    public static func openAIResponsesSupportsImageInput(modelName _: String) -> Bool {
        false
    }

    public static func claudeMessagesSupportsImageInput(modelName: String) -> Bool {
        let lowered = modelName.lowercased()
        if lowered.contains("claude-2") || lowered.contains("claude-instant") {
            return false
        }
        let visionFamilies = [
            "claude-3", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4",
            "claude-4", "claude-sonnet-3", "claude-opus-3", "claude-haiku-3",
        ]
        return visionFamilies.contains(where: lowered.contains)
    }

    private static func matchesAnchoredPrefix(_ name: String, prefix: String) -> Bool {
        let chars = Array(name)
        let prefixChars = Array(prefix)
        guard prefixChars.count <= chars.count else { return false }

        var startIndices: [Int] = [0]
        for (i, c) in chars.enumerated() where c == "/" || c == ":" {
            startIndices.append(i + 1)
        }
        for start in startIndices {
            guard start + prefixChars.count <= chars.count else { continue }
            if Array(chars[start..<start + prefixChars.count]) == prefixChars {
                let after = start + prefixChars.count
                if after == chars.count || chars[after] == "-" {
                    return true
                }
            }
        }
        return false
    }
}

private enum OpenAIChatCompletionsVisionModels {
    static let substringTokens: [String] = [
        "gpt-4o",
        "gpt-4-turbo",
        "gpt-4.1",
    ]

    static let anchoredPrefixes: [String] = [
        "o1",
        "o3",
    ]
}
