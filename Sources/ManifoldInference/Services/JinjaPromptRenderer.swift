import Foundation
import Jinja

/// Renders a model's *actual* embedded GGUF Jinja chat template via `swift-jinja`.
///
/// GGUF models loaded by the local backends do not apply their own chat
/// templates — the caller must wrap messages in the format the model was
/// trained on. Historically ManifoldKit approximated this with the hand-rolled
/// ``PromptTemplate`` enum: detection picks the nearest case, then a bespoke
/// `format*` function emits a *best-effort* version of that family's layout.
///
/// That approximation is a silent-correctness gap. Many in-use models ship
/// bespoke Jinja that the enum cannot reproduce — e.g. Qwen2.5 injects a
/// mandatory default system turn ("You are Qwen, created by Alibaba Cloud…")
/// and Llama-3.2 emits a "Cutting Knowledge Date / Today Date" preamble. The
/// enum drops both, so the model receives a structurally different prompt than
/// it was trained on, producing degraded output with no error (#1811).
///
/// This renderer closes that gap: when a GGUF carries a usable Jinja chat
/// template, render the *real* template. The enum remains the fallback for
/// templateless models and for templates `swift-jinja` cannot evaluate.
///
/// ## Structured rendering (#1909)
///
/// A real chat template is a *structured* renderer: its `{% if tools %}` and
/// `{% for tool_call in message.tool_calls %}` branches need the tool
/// definitions and the per-message tool-call / tool-result structure. An
/// earlier version of this renderer was fed the text-only `(role, content)`
/// projection and hard-coded `tools: []`, so every tool-bearing template
/// silently dropped its entire tool grammar — yielding a ~0% tool-call rate on
/// gemma-4 and the generic-preamble fallback (never the native format) on every
/// other templated model. This renderer now consumes ``StructuredMessage`` and
/// the live ``ToolDefinition`` array, threading both into the template context.
enum JinjaPromptRenderer {

    /// Roles that map onto a chat-template `messages` array. Anything else is
    /// dropped before rendering — the enum path makes the same choice.
    private static let renderableRoles: Set<String> = ["system", "user", "assistant", "tool"]

    /// Renders `messages` against a raw Jinja chat-template string.
    ///
    /// - Parameters:
    ///   - rawTemplate: the model's embedded `tokenizer.chat_template` Jinja
    ///     string (from ``ModelInfo/chatTemplateRaw``).
    ///   - messages: the structured conversation history. Tool-call and
    ///     tool-result parts are threaded into the template context so a native
    ///     tool template renders its `tool_calls` / `tool_call_id` blocks.
    ///   - systemPrompt: an optional system instruction. Prepended as a leading
    ///     `system` message when the history does not already start with one —
    ///     this matches what every chat template expects (a system turn at index
    ///     0) and lets the template's own "inject default system prompt" branch
    ///     fire only when the host supplied none.
    ///   - tools: the tool definitions to expose to the template's `{% if tools %}`
    ///     branch. Empty means "no tools" — the branch evaluates falsey. Each
    ///     tool is exposed in both the OpenAI-style nested `function` shape and
    ///     the flat `name`/`description`/`parameters` shape so templates written
    ///     against either convention (e.g. gemma's `format_parameters` macro vs
    ///     OpenAI's `tool.function.name`) both resolve.
    /// - Returns: the rendered prompt, or `nil` when the template cannot be
    ///   parsed or evaluated. A `nil` return is the signal for the caller to
    ///   fall back to the ``PromptTemplate`` enum — never a hard failure, since
    ///   a malformed embedded template must not block generation.
    static func render(
        rawTemplate: String,
        messages: [StructuredMessage],
        systemPrompt: String?,
        tools: [ToolDefinition] = []
    ) -> String? {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var jinjaMessages: [[String: Any]] = []

        // Only synthesize a leading system message when the host supplied one and
        // the history does not already open with a system turn. If the host gave
        // no system prompt, we deliberately omit it so the template's own
        // default-system branch (Qwen2.5 et al.) can fire.
        let historyHasLeadingSystem = messages.first?.role == "system"
        if let systemPrompt, !systemPrompt.isEmpty, !historyHasLeadingSystem {
            jinjaMessages.append(["role": "system", "content": systemPrompt])
        }

        for message in messages where renderableRoles.contains(message.role) {
            jinjaMessages.append(jinjaMessage(from: message))
        }

        do {
            // Render with the SAME whitespace semantics Hugging Face
            // `transformers.apply_chat_template` uses — `trim_blocks=True` and
            // `lstrip_blocks=True`. swift-jinja defaults both to `false`, so
            // without this a template that relies on block trimming (the HF
            // default, and common in real `chat_template` strings) renders with
            // spurious newlines/indentation the model never saw in training —
            // a silent fidelity drift the byte-match goldens (#1938) caught.
            // Templates that already use explicit `{%-`/`-%}` controls (Qwen,
            // Llama-3.2) are unaffected; this only fixes the ones that don't.
            let template = try Template(trimmed, with: .init(lstripBlocks: true, trimBlocks: true))
            let context: [String: Value] = [
                "messages": try Value(any: jinjaMessages),
                "add_generation_prompt": true,
                // Native tool templates branch on `tools` being defined and
                // non-empty; supply the real definitions (#1909). An empty array
                // keeps `{%- if tools %}` falsey for tool-less turns.
                "tools": try Value(any: toolsContext(tools)),
                // Many templates also branch on `documents` (RAG retrieval). Pass
                // an empty array so `{% if documents %}` is falsey rather than
                // raising an "undefined" error in stricter templates.
                "documents": try Value(any: [Any]()),
            ]
            let rendered = try template.render(context)
            // A template that evaluates to empty output is not usable — treat it
            // as a miss so the enum fallback produces a real prompt. Log it: an
            // empty render is otherwise a silent capability loss (the caller
            // degrades to the text-only enum), the same failure class as the
            // catch branch below.
            if rendered.isEmpty {
                Log.inference.warning(
                    "JinjaPromptRenderer: embedded chat template rendered empty output, falling back to enum."
                )
                return nil
            }
            return rendered
        } catch {
            // Do not crash generation on a malformed or unsupported embedded
            // template — log and let the caller fall back to the enum. This is a
            // recoverable boundary condition, not a programmer error.
            Log.inference.warning(
                "JinjaPromptRenderer: failed to render embedded chat template, falling back to enum: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Builds the per-message Jinja dictionary, threading the native tool-call /
    /// tool-result structure that the text-only projection used to drop (#1909).
    private static func jinjaMessage(from message: StructuredMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": message.role,
            "content": message.textContent,
        ]

        // Assistant tool calls → the OpenAI-style `tool_calls` array that a
        // native template iterates with `{% for tool_call in message.tool_calls %}`.
        let toolCalls: [[String: Any]] = message.parts.compactMap { part in
            guard case .toolCall(let call) = part else { return nil }
            let function: [String: Any] = [
                "name": call.toolName,
                "arguments": argumentsValue(call.arguments),
            ]
            return [
                "id": call.id,
                "type": "function",
                "function": function,
                // Flat aliases for templates that read `tool_call.name` / `.arguments`.
                "name": call.toolName,
                "arguments": argumentsValue(call.arguments),
            ]
        }
        if !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls
        }

        // Tool result → `tool_call_id` + `name` the template pairs with the call.
        if let result = firstToolResult(in: message.parts) {
            dict["tool_call_id"] = result.callId
            // The text projection only carries `.text` parts; a tool turn whose
            // payload lives in the `.toolResult` carries no text, so fold the
            // result content in as the message content when text is empty.
            if (dict["content"] as? String)?.isEmpty ?? true {
                dict["content"] = result.content
            }
        }

        return dict
    }

    private static func firstToolResult(in parts: [MessagePart]) -> ToolResult? {
        for part in parts {
            if case .toolResult(let result) = part { return result }
        }
        return nil
    }

    /// Tool-call arguments are stored as a raw JSON string. Most chat templates
    /// (`format_parameters`, OpenAI-style) iterate the *parsed* object; parse
    /// when possible and fall back to the raw string for the templates that
    /// print the JSON verbatim.
    private static func argumentsValue(_ raw: String) -> Any {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return raw
        }
        return parsed
    }

    /// Converts the live ``ToolDefinition`` array into the template-facing tool
    /// context, reusing ``encodeJSONSchemaToFoundation(_:)`` so the parameter
    /// schema reaches the template in the exact JSON-Schema shape its
    /// `format_parameters`-style macro consumes.
    private static func toolsContext(_ tools: [ToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            let parameters = encodeJSONSchemaToFoundation(tool.parameters)
                ?? ["type": "object", "properties": [String: Any]()]
            let function: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters,
            ]
            return [
                "type": "function",
                "function": function,
                // Flat aliases for gemma-style templates that read `tool.name`.
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters,
            ]
        }
    }
}
