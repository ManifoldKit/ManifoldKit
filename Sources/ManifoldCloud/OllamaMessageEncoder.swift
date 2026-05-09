#if Ollama
import Foundation
import os
import ManifoldInference

enum OllamaMessageEncoder {

    // MARK: - Tool-Call Encoding / Decoding Helpers

    /// Serialise a ``ToolDefinition`` into the OpenAI `tools` envelope shape
    /// Ollama accepts:
    ///
    /// ```json
    /// { "type": "function",
    ///   "function": { "name": "...", "description": "...", "parameters": {...} } }
    /// ```
    ///
    /// `parameters` round-trips through a JSON encode/decode so the
    /// `JSONSchemaValue` tree emerges as a plain dictionary/array graph —
    /// `JSONSerialization` accepts only Foundation primitives and chokes on
    /// the enum otherwise.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let parameters = Self.foundationJSON(from: tool.parameters) {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return [
            "type": "function",
            "function": function,
        ]
    }

    /// Serialise a ``ToolAwareHistoryEntry`` into Ollama's message shape.
    ///
    /// Assistant entries with `toolCalls` get a `tool_calls` array; tool-role
    /// entries get `tool_call_id`. Plain turns collapse to the same
    /// `{role, content}` shape the classic history path produces.
    static func encodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "role": entry.role,
            "content": entry.content,
        ]
        if let calls = entry.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map(Self.encodeToolCall)
        }
        if let callId = entry.toolCallId {
            obj["tool_call_id"] = callId
        }
        return obj
    }

    /// Serialise a single ``ToolCall`` into the OpenAI streaming-compatible
    /// shape Ollama uses in `message.tool_calls`.
    ///
    /// Ollama's server validator parses `arguments` as a JSON object when the
    /// tool call is fed back in an assistant history entry, so we
    /// re-hydrate the stored JSON string into a Foundation dictionary before
    /// emitting. When parsing fails we fall back to an empty object rather
    /// than shipping a malformed payload — the server will reject the
    /// request either way, and a clean empty-args call surfaces a more
    /// actionable error for the host.
    static func encodeToolCall(_ call: ToolCall) -> [String: Any] {
        let argumentsValue: Any = Self.parseArgumentString(call.arguments)
        return [
            "id": call.id,
            "type": "function",
            "function": [
                "name": call.toolName,
                "arguments": argumentsValue,
            ] as [String: Any],
        ]
    }

    /// Parse a `ToolCall.arguments` JSON string into the primitive graph
    /// Ollama expects inside an assistant `tool_calls[]` entry. Falls back
    /// to an empty object with a log warning on malformed input rather than
    /// swallowing the error.
    static func parseArgumentString(_ arguments: String) -> Any {
        guard let data = arguments.data(using: .utf8) else {
            Log.inference.warning(
                "OllamaBackend: tool arguments string was not valid UTF-8 — substituting empty object in history."
            )
            return [String: Any]()
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            Log.inference.warning(
                "OllamaBackend: tool arguments string was not valid JSON — substituting empty object in history. error=\(error.localizedDescription, privacy: .public)"
            )
            return [String: Any]()
        }
    }

    /// Decode one `tool_calls[]` entry from a parsed NDJSON line.
    ///
    /// Ollama's streaming format follows the OpenAI shape:
    /// `{id, type: "function", function: {name, arguments}}`. The `arguments`
    /// field is sometimes a JSON string (the documented wire shape) and
    /// sometimes a pre-parsed dictionary (observed on some Ollama builds);
    /// the decoder handles both and always produces a ``ToolCall`` whose
    /// `arguments` property is a valid JSON string.
    ///
    /// `id` is optional on the wire — some Ollama builds omit it for the
    /// first tool call in a turn. Synthesise a deterministic fallback from
    /// the tool name plus a counter suffix when absent so downstream
    /// call/result pairing still works.
    static func decodeToolCall(_ raw: [String: Any]) -> ToolCall? {
        // Two observed shapes on the wire:
        //   A) {id, type: "function", function: {name, arguments}}  — documented
        //   B) {id, name, arguments}                                 — some 0.3.x builds
        // Prefer the nested `function` envelope; fall back to the flat shape
        // when it's absent so lenient Ollama forks still produce tool events.
        let nameSource: [String: Any]
        if let function = raw["function"] as? [String: Any] {
            nameSource = function
        } else {
            nameSource = raw
        }
        guard let name = nameSource["name"] as? String, !name.isEmpty else {
            return nil
        }

        let id: String
        if let wireId = raw["id"] as? String, !wireId.isEmpty {
            id = wireId
        } else {
            // Deterministic fallback: ids are only used for id→result pairing
            // inside one turn, so a name-based placeholder is sufficient.
            id = "ollama-\(name)-\(UUID().uuidString.prefix(8))"
        }

        let argumentsString: String
        if let raw = nameSource["arguments"] as? String {
            argumentsString = raw
        } else if let dict = nameSource["arguments"] as? [String: Any] {
            argumentsString = Self.serialiseArgumentDictionary(dict)
        } else {
            argumentsString = "{}"
        }

        return ToolCall(id: id, toolName: name, arguments: argumentsString)
    }

    /// Encode a ``JSONSchemaValue`` into the primitive graph
    /// `JSONSerialization` accepts. Returns `nil` if encoding fails — callers
    /// are expected to substitute a conservative default.
    ///
    /// Delegates to `encodeJSONSchemaToFoundation(_:)` in `ManifoldInference`
    /// so all backends share one implementation.
    static func foundationJSON(from value: JSONSchemaValue) -> Any? {
        encodeJSONSchemaToFoundation(value)
    }

    /// Serialise an already-parsed arguments dictionary to a JSON string,
    /// normalising Ollama builds that emit structured `arguments` instead of
    /// the documented stringified form. Falls back to `"{}"` when
    /// serialisation fails so ``ToolCall/arguments`` always contains valid
    /// JSON the registry can decode.
    static func serialiseArgumentDictionary(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            Log.inference.warning(
                "OllamaBackend: tool arguments dictionary serialised to non-UTF8 bytes — substituting empty object."
            )
            return "{}"
        } catch {
            Log.inference.warning(
                "OllamaBackend: failed to serialise parsed tool arguments — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }

    /// Applies ``GenerationConfig/toolChoice`` to an Ollama request body.
    static func applyToolChoice(_ choice: ToolChoice, into body: inout [String: Any]) {
        switch choice {
        case .auto:
            break
        case .none:
            body["tool_choice"] = "none"
        case .required:
            body["tool_choice"] = "required"
        case .tool(let name):
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": name],
            ]
        }
    }
}
#endif
