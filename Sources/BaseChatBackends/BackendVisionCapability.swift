import BaseChatInference

/// Centralized, testable capability gates for image-input support.
///
/// The helpers live outside trait-gated backend files so CI can exercise the
/// declarations with default traits disabled. Returning `true` means the
/// backend has both a model family known to accept images and an implemented
/// request/generation path that preserves ``MessagePart/image`` payloads.
enum BackendVisionCapability {
    static var llamaSupportsImageInput: Bool { false }

    static func mlxSupportsImageInput(probedCapabilities: ModelCapabilities?) -> Bool {
        probedCapabilities?.supportsVision ?? false
    }

    static func openAIChatCompletionsSupportsImageInput(modelName: String) -> Bool {
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

    static func openAIResponsesSupportsImageInput(modelName _: String) -> Bool {
        false
    }

    static func claudeMessagesSupportsImageInput(modelName: String) -> Bool {
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
