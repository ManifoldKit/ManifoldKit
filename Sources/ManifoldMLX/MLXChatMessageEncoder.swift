#if MLX
import CoreImage
import Foundation
import MLXLMCommon
import ManifoldInference

/// Encodes Manifold chat history into the message shapes accepted by MLX.
// @_spi(Testing): published only for backend test targets (companion-package split, #1749).
@_spi(Testing) public enum MLXChatMessageEncoder {
    /// Assembles the prepared chat-message inputs for the MLX container's two
    /// `prepare(...)` overloads. Returns both shapes because the caller picks
    /// `prepare(chat:)` for vision history (non-nil first element) and
    /// `prepare(messages:)` otherwise.
    public static func buildChatMessages(
        prompt: String,
        effectiveSystemPrompt: String?,
        conversationHistory: [(role: String, content: String)],
        toolAwareHistory: [ToolAwareHistoryEntry]?,
        structuredHistory: [StructuredMessage]?,
        dialect: MLXToolDialect
    ) throws -> (chatMessages: [Chat.Message]?, messages: [[String: String]]) {
        let chatMessages: [Chat.Message]? =
            if let structuredHistory, !structuredHistory.isEmpty {
                if let toolAwareHistory, !toolAwareHistory.isEmpty {
                    try toolAwareChatMessages(
                        structuredHistory: structuredHistory,
                        toolAwareHistory: toolAwareHistory,
                        systemPrompt: effectiveSystemPrompt,
                        dialect: dialect
                    )
                } else {
                    try plainChatMessages(
                        history: structuredHistory,
                        systemPrompt: effectiveSystemPrompt
                    )
                }
            } else {
                nil
            }

        var msgs: [[String: String]] = []
        if let sp = effectiveSystemPrompt, !sp.isEmpty {
            msgs.append(["role": "system", "content": sp])
        }
        if let toolHistory = toolAwareHistory, !toolHistory.isEmpty {
            for entry in toolHistory {
                msgs.append(encodeToolAwareEntryAsText(entry, dialect: dialect))
            }
        } else if !conversationHistory.isEmpty {
            for msg in conversationHistory {
                msgs.append(["role": msg.role, "content": msg.content])
            }
        } else {
            msgs.append(["role": "user", "content": prompt])
        }
        return (chatMessages, msgs)
    }

    /// Returns the Qwen 2.5 `<tools>…</tools>` block to append to the system
    /// prompt, or `nil` when the dialect doesn't use this mechanism or the
    /// caller supplied no tools.
    public static func buildQwenToolBlock(
        config: GenerationConfig,
        dialect: MLXToolDialect
    ) -> String? {
        guard !config.tools.isEmpty, dialect == .qwen25 else { return nil }
        let toolObjects: [[String: Any]] = config.tools.map { tool -> [String: Any] in
            var function_: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            if let paramsData = try? JSONEncoder().encode(tool.parameters),
               let paramsObj = try? JSONSerialization.jsonObject(with: paramsData) {
                function_["parameters"] = paramsObj
            } else {
                function_["parameters"] = ["type": "object", "properties": [String: Any]()] 
            }
            return ["type": "function", "function": function_]
        }
        let toolsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: toolObjects, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            toolsJSON = str
        } else {
            toolsJSON = "[]"
        }
        return "\n\n# Tools\n\nYou may call one or more functions to assist with the user query. Don't make assumptions about what values to plug into functions. Here are the available tools:\n\n<tools>\n\(toolsJSON)\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags as follows:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"
    }

    /// Encodes a ``ToolAwareHistoryEntry`` into a plain `[String: String]` message
    /// compatible with MLX chat-template preparation.
    ///
    /// For the Qwen 2.5 dialect:
    /// - Assistant entries with `toolCalls` have the calls serialised as
    ///   `<tool_call>{"name":…, "arguments":…}</tool_call>` appended to (or
    ///   replacing) the textual content.
    /// - Tool-role entries (carrying a ``ToolResult``) are represented as
    ///   `role: "tool"` with the result content. The MLX chat template for
    ///   Qwen maps the `tool` role to an `<tool_response>` block internally.
    ///
    /// For the `.unknown` dialect (and plain text turns) the entry collapses to
    /// a simple `{role, content}` pair.
    static func encodeToolAwareEntryAsText(
        _ entry: ToolAwareHistoryEntry,
        dialect: MLXToolDialect
    ) -> [String: String] {
        // For non-Qwen dialects or plain turns, fall back to the bare shape.
        guard dialect == .qwen25 else {
            return ["role": entry.role, "content": entry.content]
        }

        if let calls = entry.toolCalls, !calls.isEmpty {
            // Assistant turn that triggered tool calls: encode calls as text.
            var parts: [String] = []
            if !entry.content.isEmpty {
                parts.append(entry.content)
            }
            for call in calls {
                let argsValue: Any
                if let data = call.arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    argsValue = parsed
                } else {
                    argsValue = [String: Any]()
                }
                let callObj: [String: Any] = ["name": call.toolName, "arguments": argsValue]
                if let data = try? JSONSerialization.data(withJSONObject: callObj),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    parts.append("<tool_call>\n\(jsonStr)\n</tool_call>")
                }
            }
            return ["role": "assistant", "content": parts.joined(separator: "\n")]
        }

        // Tool result turn: pass role and content as-is.
        // The Qwen tokenizer template handles `role: "tool"` natively.
        return ["role": entry.role, "content": entry.content]
    }

    private static func chatRole(for role: String) -> Chat.Message.Role {
        switch role {
        case "assistant": .assistant
        case "system": .system
        case "tool": .tool
        default: .user
        }
    }

    private static func userInputImage(from data: Data, mimeType: String) throws -> UserInput.Image {
        guard let image = CIImage(data: data) else {
            throw InferenceError.inferenceFailure(
                "Unsupported image attachment format (\(mimeType))."
            )
        }
        return .ciImage(image)
    }

    private static func imageInputs(from parts: [MessagePart]) throws -> [UserInput.Image] {
        try parts.compactMap { part in
            guard case let .image(data, mimeType, _) = part else { return nil }
            return try userInputImage(from: data, mimeType: mimeType)
        }
    }

    private static func plainChatMessages(
        history: [StructuredMessage],
        systemPrompt: String?
    ) throws -> [Chat.Message]? {
        let containsImages = history.contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }
        guard containsImages else { return nil }

        var messages: [Chat.Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }
        for message in history {
            messages.append(
                Chat.Message(
                    role: chatRole(for: message.role),
                    content: message.textContent,
                    images: try imageInputs(from: message.parts)
                )
            )
        }
        return messages
    }

    private static func toolAwareChatMessages(
        structuredHistory: [StructuredMessage],
        toolAwareHistory: [ToolAwareHistoryEntry],
        systemPrompt: String?,
        dialect: MLXToolDialect
    ) throws -> [Chat.Message]? {
        guard structuredHistory.contains(where: { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }) else {
            return nil
        }

        var messages: [Chat.Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }

        let structuredImageParts = try structuredHistory.map { try imageInputs(from: $0.parts) }
        for (index, entry) in toolAwareHistory.enumerated() {
            let encoded = encodeToolAwareEntryAsText(entry, dialect: dialect)
            let role = encoded["role"] ?? entry.role
            let content = encoded["content"] ?? entry.content
            let images = index < structuredImageParts.count ? structuredImageParts[index] : []
            messages.append(
                Chat.Message(
                    role: chatRole(for: role),
                    content: content,
                    images: images
                )
            )
        }

        if toolAwareHistory.count < structuredHistory.count {
            for (offset, structuredMessage) in structuredHistory.dropFirst(toolAwareHistory.count).enumerated() {
                let images = structuredImageParts[toolAwareHistory.count + offset]
                messages.append(
                    Chat.Message(
                        role: chatRole(for: structuredMessage.role),
                        content: structuredMessage.textContent,
                        images: images
                    )
                )
            }
        }

        return messages
    }
}
#endif
