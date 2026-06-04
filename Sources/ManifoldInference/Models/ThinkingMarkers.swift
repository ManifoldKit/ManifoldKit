public struct ThinkingMarkers: Sendable, Equatable, Codable {
    public let open: String
    public let close: String

    /// Bytes to hold back at chunk boundary — prevents partial-tag emission.
    public var holdback: Int { max(open.count, close.count) }

    public init(open: String, close: String) {
        self.open = open
        self.close = close
    }

    /// Qwen3, DeepSeek-R1 (and distillations), and QwQ inline thinking tags.
    public static let qwen3 = ThinkingMarkers(open: "<think>", close: "</think>")

    /// Mistral Small 3.1 reasoning fine-tunes and Sky-T1 models, which emit
    /// `<thinking>` / `</thinking>` instead of the Qwen-style `<think>` pair.
    public static let mistralReasoning = ThinkingMarkers(open: "<thinking>", close: "</thinking>")

    /// phi4-reasoning and some older Reflection variants that wrap their
    /// chain-of-thought in `<reasoning>` / `</reasoning>`.
    public static let phi4 = ThinkingMarkers(open: "<reasoning>", close: "</reasoning>")

    /// Reflection-Llama 3.1 (and derivatives), which emits self-critique in
    /// `<reflection>` / `</reflection>` blocks distinct from its `<thinking>` pass.
    public static let reflection = ThinkingMarkers(open: "<reflection>", close: "</reflection>")

    /// Gemma 4 thinking fine-tunes, which wrap chain-of-thought in a dedicated
    /// `<|turn>think\n` turn that closes with the standard `<|end_of_turn>` delimiter.
    ///
    /// The close marker collides with normal turn separators, but `ThinkingTransform` is
    /// only active when thinking mode is enabled — and a thinking block always appears
    /// at the start of the model turn before any visible content — so the parser
    /// correctly transitions to visible-text mode after the first `<|end_of_turn>`.
    public static let gemma4 = ThinkingMarkers(open: "<|turn>think\n", close: "<|end_of_turn>")

    /// Extensibility hook for custom model formats.
    public static func custom(open: String, close: String) -> ThinkingMarkers {
        ThinkingMarkers(open: open, close: close)
    }

    /// Returns the most-specific preset for a given model name via case-insensitive
    /// substring match, or `nil` if no known family matches.
    ///
    /// Match precedence (most specific first):
    /// - `reflection-llama` → `.reflection`
    /// - `phi4` / `phi-4` → `.phi4`
    /// - `qwen` / `deepseek` / `qwq` → `.qwen3`
    /// - `mistral` / `sky-t1` → `.mistralReasoning`
    ///
    /// Only `phi4` / `phi-4` map to `.phi4` — generic `phi` or other Phi
    /// generations (e.g. `phi3`) are not thinking-model variants and return
    /// `nil`. Unknown models likewise return `nil` so callers can opt out of
    /// thinking-tag filtering cleanly.
    /// Returns the most-specific preset for a given Jinja chat-template string
    /// by sniffing the open/close marker pairs the template references.
    ///
    /// Both halves of a pair (e.g. `<think>` and `</think>`) must appear for
    /// that family to be returned. A template with neither pair returns `nil`,
    /// letting backends opt out of thinking parsing on non-reasoning models.
    /// See ``PromptTemplateDetector/detectThinkingMarkers(from:)`` for the full
    /// precedence rules.
    public static func fromChatTemplate(_ chatTemplate: String) -> ThinkingMarkers? {
        PromptTemplateDetector.detectThinkingMarkers(from: chatTemplate)
    }

    public static func forModel(named name: String) -> ThinkingMarkers? {
        let lowered = name.lowercased()

        // Most-specific matches first — `reflection-llama` wins over a bare
        // `reflection` substring match, and `phi-4`/`phi4` wins over generic `phi`.
        if lowered.contains("reflection-llama") {
            return .reflection
        }
        if lowered.contains("phi4") || lowered.contains("phi-4") {
            return .phi4
        }

        if lowered.contains("qwen") || lowered.contains("deepseek") || lowered.contains("qwq") {
            return .qwen3
        }
        if lowered.contains("mistral") || lowered.contains("sky-t1") {
            return .mistralReasoning
        }

        return nil
    }
}
