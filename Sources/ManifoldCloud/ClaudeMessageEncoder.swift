#if CloudSaaS
import Foundation
import os
import ManifoldInference

/// Encodes Manifold structured and tool-aware history into Anthropic Messages API payloads.
enum ClaudeMessageEncoder {
    /// Encodes one ``StructuredMessage`` as an Anthropic Messages API `messages[]` entry.
    static func encodeMessageContent(for message: StructuredMessage) -> [String: Any] {
        if message.role == "assistant" {
            var blocks: [[String: Any]] = []

            for part in message.parts {
                if case .thinking(let text, let signature) = part {
                    guard let signature else { continue }
                    blocks.append([
                        "type": "thinking",
                        "thinking": text,
                        "signature": signature
                    ])
                }
            }

            for part in message.parts {
                if case .image(let data, let mimeType, _) = part {
                    blocks.append(encodeImageBlock(data: data, mimeType: mimeType))
                }
            }

            let visible = message.textContent
            if !visible.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": visible
                ])
            }

            if blocks.isEmpty {
                return ["role": "assistant", "content": ""]
            }
            return ["role": "assistant", "content": blocks]
        }

        let hasImage = message.parts.contains { part in
            if case .image = part { return true }
            return false
        }
        if message.role == "user", hasImage {
            var blocks: [[String: Any]] = []
            for part in message.parts {
                if case .image(let data, let mimeType, _) = part {
                    blocks.append(encodeImageBlock(data: data, mimeType: mimeType))
                }
            }
            let text = message.textContent
            if !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            return ["role": "user", "content": blocks]
        }

        return ["role": message.role, "content": message.textContent]
    }

    /// Encodes a single image part as an Anthropic image content block.
    static func encodeImageBlock(data: Data, mimeType: String) -> [String: Any] {
        let normalised = mimeType.lowercased()
        let mediaType = CloudImageEncoding.anthropicSupportedMimeTypes.contains(normalised)
            ? normalised
            : "image/png"
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": CloudImageEncoding.base64String(from: data),
            ] as [String: Any],
        ]
    }

    /// Encodes a ``ToolDefinition`` into Anthropic's `tools[]` envelope.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var entry: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let schema = encodeJSONSchemaToFoundation(tool.parameters) {
            entry["input_schema"] = schema
        } else {
            entry["input_schema"] = ["type": "object", "properties": [String: Any]()]
        }
        return entry
    }

    /// Encodes one ``ToolAwareHistoryEntry`` for the Anthropic Messages API `messages[]` array.
    static func encodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        if entry.role == "tool", let callId = entry.toolCallId {
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": callId,
                        "content": entry.content,
                    ] as [String: Any]
                ],
            ]
        }

        if entry.role == "assistant", let calls = entry.toolCalls, !calls.isEmpty {
            var blocks: [[String: Any]] = []
            if !entry.content.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": entry.content,
                ])
            }
            for call in calls {
                let inputObj = decodeArgumentsForReplay(call.arguments)
                blocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.toolName,
                    "input": inputObj,
                ])
            }
            return ["role": "assistant", "content": blocks]
        }

        return ["role": entry.role, "content": entry.content]
    }

    /// Decodes stored arguments JSON for replay inside an Anthropic `tool_use.input` object.
    static func decodeArgumentsForReplay(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            return [:]
        }
        do {
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let object = decoded as? [String: Any] {
                return object
            }
            Log.inference.warning(
                "ClaudeMessageEncoder: tool_use input parsed but is not a JSON object — substituting empty object to satisfy Anthropic schema."
            )
            return [:]
        } catch {
            Log.inference.warning(
                "ClaudeMessageEncoder: tool_use input could not be re-parsed for replay — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }
}
#endif
