#if CloudSaaS
import Foundation
import os
import BaseChatInference

/// Helpers shared by ``OpenAIBackend`` (Chat Completions) and
/// ``OpenAIResponsesBackend`` (Responses API) for encoding the BCK
/// ``ToolDefinition`` / ``ToolChoice`` / ``ToolAwareHistoryEntry`` types into
/// OpenAI's wire format.
///
/// Chat Completions and the Responses API use the same `tools[]` envelope —
/// `{type: "function", function: {name, description, parameters}}` — and the
/// same `tool_choice` shape, so a single set of encoders covers both.
/// Tool-result feedback differs slightly between the two APIs:
///
/// - Chat Completions: `{role: "tool", tool_call_id, content}` plus an
///   assistant turn carrying `tool_calls[]`.
/// - Responses: `{type: "function_call_output", call_id, output}` plus
///   `{type: "function_call", call_id, name, arguments}` items.
///
/// The encoder for the assistant + tool turns is therefore split across two
/// helpers (`encodeChatCompletionsHistory`, `encodeResponsesInput`).
enum OpenAIToolEncoding {

    // MARK: - Tool definitions

    /// Encodes a ``ToolDefinition`` into the `{type:"function", function:{...}}`
    /// envelope used by both Chat Completions and Responses.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let parameters = foundationJSON(from: tool.parameters) {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return [
            "type": "function",
            "function": function,
        ]
    }

    // MARK: - tool_choice

    /// Applies ``GenerationConfig/toolChoice`` to a request body in the OpenAI
    /// shape. `auto` omits the field entirely (server default); `.none` /
    /// `.required` are passed as literal strings; `.tool(name:)` produces the
    /// nested function-selection object.
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

    // MARK: - History encoding (Chat Completions)

    /// Encodes a ``ToolAwareHistoryEntry`` for the Chat Completions
    /// `messages[]` array.
    ///
    /// Assistant turns with `toolCalls` get an OpenAI-shaped `tool_calls` array;
    /// tool-role turns get `tool_call_id`. Plain turns collapse to the same
    /// `{role, content}` shape.
    static func encodeChatCompletionsEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "role": entry.role,
            "content": entry.content,
        ]
        if let calls = entry.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map(encodeToolCall)
        }
        if let callId = entry.toolCallId {
            obj["tool_call_id"] = callId
        }
        return obj
    }

    /// Encodes a ``ToolCall`` in the `tool_calls[]` shape used by the
    /// Chat Completions API:
    ///
    /// ```json
    /// {"id":"...","type":"function","function":{"name":"...","arguments":"..."}}
    /// ```
    ///
    /// Per the OpenAI spec, `arguments` is a stringified JSON blob (not a
    /// pre-parsed object) on Chat Completions. We pass the stored JSON string
    /// through as-is.
    static func encodeToolCall(_ call: ToolCall) -> [String: Any] {
        return [
            "id": call.id,
            "type": "function",
            "function": [
                "name": call.toolName,
                "arguments": call.arguments,
            ] as [String: Any],
        ]
    }

    // MARK: - History encoding (Responses API)

    /// Encodes a ``ToolAwareHistoryEntry`` for the Responses API `input[]`.
    ///
    /// The Responses API expresses tool turns with separate item types — an
    /// assistant turn with `tool_calls` becomes a `function_call` item per
    /// call, and a tool-role turn becomes a `function_call_output` item.
    /// Returns one or more items per entry.
    static func encodeResponsesEntries(_ entry: ToolAwareHistoryEntry) -> [[String: Any]] {
        // Tool-role entry → function_call_output.
        if entry.role == "tool", let callId = entry.toolCallId {
            return [[
                "type": "function_call_output",
                "call_id": callId,
                "output": entry.content,
            ]]
        }

        // Assistant entry with tool_calls → one function_call item per call,
        // plus an optional preamble message if there's any visible content.
        if entry.role == "assistant", let calls = entry.toolCalls, !calls.isEmpty {
            var items: [[String: Any]] = []
            if !entry.content.isEmpty {
                items.append([
                    "role": "assistant",
                    "content": entry.content,
                ])
            }
            for call in calls {
                items.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.toolName,
                    "arguments": call.arguments,
                ])
            }
            return items
        }

        // Plain message turn.
        return [[
            "role": entry.role,
            "content": entry.content,
        ]]
    }

    // MARK: - JSONSchemaValue → Foundation primitives

    /// Encodes a ``JSONSchemaValue`` into the primitive graph
    /// `JSONSerialization` accepts. Returns `nil` if encoding fails — callers
    /// substitute a conservative empty-object default.
    ///
    /// Delegates to `encodeJSONSchemaToFoundation(_:)` in `BaseChatInference`
    /// so all backends share one implementation.
    static func foundationJSON(from value: JSONSchemaValue) -> Any? {
        encodeJSONSchemaToFoundation(value)
    }
}

// MARK: - Streaming tool-call accumulator

/// Module-internal typealias so existing call sites in `BaseChatBackends`
/// compile unchanged after the rename to ``StreamingArgumentAccumulator``
/// in `BaseChatInference`.
typealias StreamingToolCallAccumulator = StreamingArgumentAccumulator
#endif
