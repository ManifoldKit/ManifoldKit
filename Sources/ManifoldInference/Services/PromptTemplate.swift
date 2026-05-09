import Foundation

/// Prompt template formats for models that require explicit chat formatting.
///
/// GGUF models loaded via llama.cpp do not apply their own chat templates,
/// so the caller must wrap messages in the format the model was trained on.
/// MLX and Foundation backends handle formatting internally and ignore these.
public enum PromptTemplate: String, CaseIterable, Sendable, Identifiable {
    case chatML = "ChatML"
    case llama3 = "Llama 3"
    case mistral = "Mistral"
    case alpaca = "Alpaca"
    case gemma = "Gemma"
    case gemma4 = "Gemma 4"
    case phi = "Phi"

    public var id: String { rawValue }

    /// Special tokens for each template format. User content containing these
    /// tokens is sanitised before interpolation to prevent prompt injection.
    private var specialTokens: [String] {
        switch self {
        case .chatML:
            return ["<|im_start|>", "<|im_end|>"]
        case .llama3:
            return ["<|begin_of_text|>", "<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>"]
        case .mistral:
            return ["[INST]", "[/INST]", "</s>"]
        case .alpaca:
            return ["### Instruction:", "### Input:", "### Response:"]
        case .gemma:
            return ["<start_of_turn>", "<end_of_turn>"]
        case .gemma4:
            return ["<|turn>", "<|end_of_turn>", "<|tool>", "<|tool_call>", "<|tool_response>"]
        case .phi:
            return ["<|system|>", "<|user|>", "<|assistant|>", "<|end|>"]
        }
    }

    /// Strips special tokens from user-controlled text to prevent prompt injection.
    private func sanitize(_ text: String) -> String {
        var result = text
        for token in specialTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result
    }

    /// Thinking markers for this template, or nil if the template does not emit reasoning blocks.
    public var thinkingMarkers: ThinkingMarkers? {
        switch self {
        case .chatML:  return .qwen3   // Qwen3, DeepSeek-R1 use ChatML format with <think> tags
        case .gemma4:  return .gemma4  // Gemma 4 thinking fine-tunes wrap CoT in <|turn>think\n
        default:       return nil
        }
    }

    /// Formats an array of messages into a single prompt string.
    ///
    /// - Parameters:
    ///   - messages: Ordered (role, content) pairs. Roles are "user", "assistant", "system".
    ///   - systemPrompt: An optional system-level instruction prepended before messages.
    /// - Returns: A formatted prompt string ready for the model.
    public func format(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        format(messages: messages, systemPrompt: systemPrompt, tools: [])
    }

    /// Formats an array of messages into a single prompt string, injecting
    /// native tool-declaration blocks for templates that support them.
    ///
    /// Currently only `.gemma4` uses `tools` natively (via `<|tool>` blocks in
    /// the system turn). All other templates ignore the `tools` parameter and
    /// produce the same output as `format(messages:systemPrompt:)`. Tool
    /// descriptions for those templates must be injected via
    /// `ToolSystemPromptBuilder` into `systemPrompt` before calling this method.
    ///
    /// - Parameters:
    ///   - messages: Ordered (role, content) pairs.
    ///   - systemPrompt: An optional system-level instruction.
    ///   - tools: Tool definitions to inject natively when the template supports it.
    /// - Returns: A formatted prompt string ready for the model.
    public func format(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        tools: [ToolDefinition]
    ) -> String {
        switch self {
        case .chatML:
            return formatChatML(messages: messages, systemPrompt: systemPrompt)
        case .llama3:
            return formatLlama3(messages: messages, systemPrompt: systemPrompt)
        case .mistral:
            return formatMistral(messages: messages, systemPrompt: systemPrompt)
        case .alpaca:
            return formatAlpaca(messages: messages, systemPrompt: systemPrompt)
        case .gemma:
            return formatGemma(messages: messages, systemPrompt: systemPrompt)
        case .gemma4:
            return formatGemma4(messages: messages, systemPrompt: systemPrompt, tools: tools)
        case .phi:
            return formatPhi(messages: messages, systemPrompt: systemPrompt)
        }
    }

    // MARK: - ChatML

    /// ```
    /// <|im_start|>system
    /// {system}<|im_end|>
    /// <|im_start|>user
    /// {content}<|im_end|>
    /// <|im_start|>assistant
    /// ```
    private func formatChatML(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|im_start|>system\n\(sanitize(systemPrompt))<|im_end|>\n"
        }

        for message in messages {
            result += "<|im_start|>\(message.role)\n\(sanitize(message.content))<|im_end|>\n"
        }

        result += "<|im_start|>assistant\n"
        Log.prompt.debug("Formatted \(messages.count) messages with ChatML template")
        return result
    }

    // MARK: - Llama 3

    /// ```
    /// <|begin_of_text|><|start_header_id|>system<|end_header_id|>
    /// {system}<|eot_id|><|start_header_id|>user<|end_header_id|>
    /// {content}<|eot_id|><|start_header_id|>assistant<|end_header_id|>
    /// ```
    private func formatLlama3(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = "<|begin_of_text|>"

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|start_header_id|>system<|end_header_id|>\n\n\(sanitize(systemPrompt))<|eot_id|>"
        }

        for message in messages {
            result += "<|start_header_id|>\(message.role)<|end_header_id|>\n\n\(sanitize(message.content))<|eot_id|>"
        }

        result += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Llama 3 template")
        return result
    }

    // MARK: - Mistral

    /// ```
    /// [INST] {system}
    /// {content} [/INST]
    /// ```
    /// Multi-turn uses alternating `[INST]...[/INST]` and plain text.
    private func formatMistral(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        // Mistral v0.1/v0.2 style: system prompt is prepended to the first user message.
        var systemPrefix = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            systemPrefix = sanitize(systemPrompt) + "\n\n"
        }

        var isFirstUser = true
        for message in messages {
            switch message.role {
            case "user":
                let content = isFirstUser ? systemPrefix + sanitize(message.content) : sanitize(message.content)
                result += "[INST] \(content) [/INST]"
                isFirstUser = false
            case "assistant":
                result += " \(sanitize(message.content))</s>"
            default:
                break  // System messages handled via systemPrefix
            }
        }

        Log.prompt.debug("Formatted \(messages.count) messages with Mistral template")
        return result
    }

    // MARK: - Alpaca

    /// ```
    /// ### Instruction:
    /// {system}
    ///
    /// ### Input:
    /// {content}
    ///
    /// ### Response:
    /// ```
    /// Only uses the last user message (Alpaca is single-turn by design).
    private func formatAlpaca(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "### Instruction:\n\(sanitize(systemPrompt))\n\n"
        } else {
            result += "### Instruction:\nYou are a helpful assistant.\n\n"
        }

        // Alpaca is single-turn; use the last user message as input.
        if let lastUser = messages.last(where: { $0.role == "user" }) {
            result += "### Input:\n\(sanitize(lastUser.content))\n\n"
        }

        result += "### Response:\n"
        Log.prompt.debug("Formatted with Alpaca template (single-turn)")
        return result
    }

    // MARK: - Gemma

    /// ```
    /// <start_of_turn>user
    /// {system}
    ///
    /// {content}<end_of_turn>
    /// <start_of_turn>model
    /// ```
    private func formatGemma(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        // Gemma prepends system prompt to first user message.
        var systemPrefix = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            systemPrefix = sanitize(systemPrompt) + "\n\n"
        }

        var isFirstUser = true
        for message in messages {
            switch message.role {
            case "user":
                let content = isFirstUser ? systemPrefix + sanitize(message.content) : sanitize(message.content)
                result += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                isFirstUser = false
            case "assistant":
                result += "<start_of_turn>model\n\(sanitize(message.content))<end_of_turn>\n"
            default:
                break
            }
        }

        result += "<start_of_turn>model\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Gemma template")
        return result
    }

    // MARK: - Gemma 4

    /// ```
    /// <|turn>system
    /// {system}
    /// <|tool>{"name":"…","description":"…","parameters":{…}}   ← one per tool
    /// <|end_of_turn>
    /// <|turn>user
    /// {content}<|end_of_turn>
    /// <|turn>model
    /// {content}<|end_of_turn>
    /// <|turn>model                 ← generation prompt (no closing delimiter)
    /// ```
    ///
    /// Unlike Gemma 1/2/3 (which prepend the system prompt to the first user turn),
    /// Gemma 4 uses an explicit `<|turn>system` turn.
    ///
    /// When `tools` is non-empty, each `ToolDefinition` is serialised as a
    /// `<|tool>{JSON}` block appended to the system turn, in the order they appear
    /// in the array. The declaration JSON has the shape
    /// `{"name":"…","description":"…","parameters":{…}}`.
    private func formatGemma4(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        tools: [ToolDefinition] = []
    ) -> String {
        var result = ""

        let hasSystemContent = systemPrompt != nil && !(systemPrompt!.isEmpty)
        var systemParts: [String] = []
        if hasSystemContent {
            systemParts.append(sanitize(systemPrompt!))
        }
        for tool in tools {
            if let block = toolDeclarationBlock(for: tool) {
                systemParts.append("<|tool>\(block)")
            } else {
                // Silent skip would mask a tool author's mistake during prompt
                // assembly. Surface it in the prompt log so the failure is
                // discoverable without crashing generation.
                Log.prompt.error("Failed to serialize tool declaration for Gemma 4 template: \(tool.name)")
            }
        }
        // Only emit the system turn when at least one part survived
        // serialisation — otherwise we'd ship an empty `<|turn>system\n<|end_of_turn>`
        // marker that confuses the model and burns context.
        if !systemParts.isEmpty {
            result += "<|turn>system\n"
            result += systemParts.joined(separator: "\n")
            result += "<|end_of_turn>\n"
        }

        for message in messages {
            switch message.role {
            case "user":
                result += "<|turn>user\n\(sanitize(message.content))<|end_of_turn>\n"
            case "assistant":
                result += "<|turn>model\n\(sanitize(message.content))<|end_of_turn>\n"
            default:
                break
            }
        }

        result += "<|turn>model\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Gemma 4 template")
        return result
    }

    /// Serialises a `ToolDefinition` to the JSON string placed after `<|tool>`.
    /// Returns `nil` when serialisation fails (the tool is silently skipped).
    private func toolDeclarationBlock(for tool: ToolDefinition) -> String? {
        guard let paramsData   = try? JSONEncoder().encode(tool.parameters),
              let paramsObject = try? JSONSerialization.jsonObject(with: paramsData)
        else { return nil }

        let dict: [String: Any] = [
            "name":        tool.name,
            "description": tool.description,
            "parameters":  paramsObject
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys),
              let str  = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    // MARK: - Phi

    /// ```
    /// <|system|>
    /// {system}<|end|>
    /// <|user|>
    /// {content}<|end|>
    /// <|assistant|>
    /// ```
    private func formatPhi(
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String {
        var result = ""

        if let systemPrompt, !systemPrompt.isEmpty {
            result += "<|system|>\n\(sanitize(systemPrompt))<|end|>\n"
        }

        for message in messages {
            switch message.role {
            case "user":
                result += "<|user|>\n\(sanitize(message.content))<|end|>\n"
            case "assistant":
                result += "<|assistant|>\n\(sanitize(message.content))<|end|>\n"
            case "system":
                result += "<|system|>\n\(sanitize(message.content))<|end|>\n"
            default:
                break
            }
        }

        result += "<|assistant|>\n"
        Log.prompt.debug("Formatted \(messages.count) messages with Phi template")
        return result
    }
}
