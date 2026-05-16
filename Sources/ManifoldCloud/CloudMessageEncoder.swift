#if CloudSaaS || Ollama
import Foundation
import os
import ManifoldInference

// MARK: - Cache breakpoint plan

/// Describes the cache breakpoints a request body should receive before
/// hitting the wire. Today only Anthropic Claude surfaces explicit
/// `cache_control` markers; OpenAI Chat Completions, OpenAI Responses, and
/// Ollama use prefix-stable caching server-side and therefore don't
/// participate in this annotation step.
///
/// Phase 1b carrier; Phase 2 will move the policy decision to a
/// `PromptCachePolicy` composed property on the adapter (see plan item 4
/// from the AI-engineering review).
public struct CacheBreakpointPlan: Sendable, Equatable {
    /// Maximum number of explicit breakpoints permitted in the request.
    /// Anthropic caps at 4; other providers ignore this field.
    public var maxBreakpoints: Int
    /// When `true`, attach `cache_control: { type: "ephemeral" }` to the
    /// system prompt block. No-op for non-Claude providers.
    public var cacheSystem: Bool
    /// When `true`, attach `cache_control: { type: "ephemeral" }` to the
    /// last tool definition. No-op for non-Claude providers.
    public var cacheToolsTail: Bool

    public init(maxBreakpoints: Int = 4, cacheSystem: Bool = false, cacheToolsTail: Bool = false) {
        self.maxBreakpoints = maxBreakpoints
        self.cacheSystem = cacheSystem
        self.cacheToolsTail = cacheToolsTail
    }
}

// MARK: - CloudMessageEncoder

/// Provider-keyed message-encoding facade for cloud backends.
///
/// Phase 1b/B of the cross-backend unification plan: collapses
/// `ClaudeMessageEncoder` + `OllamaMessageEncoder` + the OpenAI inline
/// encoding into one enum so the surface (`encodeMessages`, `encodeTools`,
/// `encodeToolResults`, `annotateCacheBreakpoints`) is the same shape
/// across every provider. Phase 2 will dissolve this enum behind the
/// composed `CloudHTTPProviderAdapter` (each case becomes an adapter's
/// `MessageEncoding` witness).
///
/// Each method returns Foundation primitive graphs (`[[String: Any]]`,
/// `[Any]`) ready for `JSONSerialization.data(withJSONObject:)`. Callers
/// own ordering decisions (system prompt prepending, history precedence)
/// — the encoder is stateless and per-message.
public enum CloudMessageEncoder: Sendable {
    case openAI
    case openAIResponses
    case claude
    case ollama

    // MARK: encodeMessages

    /// Encodes a history into the provider's `messages[]` / `input[]`
    /// shape. Tool-aware history wins over structured history wins over
    /// plain history wins over the lone prompt turn — same precedence the
    /// per-backend `buildRequest` implementations used pre-refactor.
    ///
    /// - Parameters:
    ///   - systemPrompt: optional system instruction. Claude moves this
    ///     to a top-level `system` field on the request body and is
    ///     therefore expected to be `nil` here for Claude callers.
    ///     Others prepend it as a `{role: "system"}` entry when non-empty.
    ///   - prompt: the lone user turn used when every history source is
    ///     empty/`nil`.
    ///   - structuredHistory: vision-aware history. Used by OpenAI Chat
    ///     Completions when at least one part is an image; used by Claude
    ///     when present at all.
    ///   - toolAwareHistory: tool-call replay history. When non-empty
    ///     this wins over `structuredHistory`.
    ///   - plainHistory: legacy `(role, content)` history fallback.
    public func encodeMessages(
        systemPrompt: String?,
        prompt: String,
        structuredHistory: [StructuredMessage]?,
        toolAwareHistory: [ToolAwareHistoryEntry]?,
        plainHistory: [(role: String, content: String)]?
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty, needsInlineSystemEntry {
            out.append(["role": "system", "content": systemPrompt])
        }

        if let toolAwareHistory, !toolAwareHistory.isEmpty {
            for entry in toolAwareHistory {
                out.append(contentsOf: encodeToolAwareEntry(entry))
            }
            return out
        }

        if let structuredHistory, !structuredHistory.isEmpty, supportsStructuredHistory {
            for message in structuredHistory {
                out.append(encodeStructuredMessage(message))
            }
            return out
        }

        if let plainHistory, !plainHistory.isEmpty {
            for turn in plainHistory {
                out.append(["role": turn.role, "content": turn.content])
            }
            return out
        }

        out.append(["role": "user", "content": prompt])
        return out
    }

    // MARK: encodeTools

    /// Encodes a list of ``ToolDefinition`` into the provider's
    /// `tools[]` envelope. Returns an empty array when `tools` is empty.
    public func encodeTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        guard !tools.isEmpty else { return [] }
        switch self {
        case .openAI, .openAIResponses:
            #if CloudSaaS
            return tools.map(OpenAIToolEncoding.encodeToolDefinition)
            #else
            return []
            #endif
        case .claude:
            #if CloudSaaS
            return tools.map(Self.claudeEncodeToolDefinition)
            #else
            return []
            #endif
        case .ollama:
            #if Ollama
            return tools.map(Self.ollamaEncodeToolDefinition)
            #else
            return []
            #endif
        }
    }

    // MARK: encodeToolResults

    /// Encodes a list of tool results (one per tool the model called) into
    /// the provider's history shape. The result for `.claude` is a single
    /// `user` turn carrying one or more `tool_result` content blocks;
    /// `.openAI` / `.openAIResponses` / `.ollama` return one entry per
    /// result. AI-engineering plan item 7 — explicit, not implicit.
    public func encodeToolResults(_ results: [ToolResult]) -> [[String: Any]] {
        guard !results.isEmpty else { return [] }
        switch self {
        case .openAI, .ollama:
            // Chat Completions / Ollama: each result is a `{role: "tool", tool_call_id, content}` entry.
            return results.map { result in
                [
                    "role": "tool",
                    "tool_call_id": result.callId,
                    "content": result.content,
                ]
            }
        case .openAIResponses:
            // Responses API: each result is a `function_call_output` item.
            return results.map { result in
                [
                    "type": "function_call_output",
                    "call_id": result.callId,
                    "output": result.content,
                ]
            }
        case .claude:
            #if CloudSaaS
            // Anthropic Messages: bundle every `tool_result` into one user turn.
            let blocks: [[String: Any]] = results.map { result in
                [
                    "type": "tool_result",
                    "tool_use_id": result.callId,
                    "content": result.content,
                ]
            }
            return [["role": "user", "content": blocks]]
            #else
            return []
            #endif
        }
    }

    // MARK: annotateCacheBreakpoints

    /// Mutates `messages` / `tools` to add provider-specific cache markers.
    /// No-op for OpenAI, OpenAI Responses, and Ollama. For Claude, attaches
    /// `cache_control: { type: "ephemeral" }` to the last tool entry and/or
    /// the system block per the plan, capped at `plan.maxBreakpoints`.
    ///
    /// `systemBlock` is the value the caller intends to set as the request
    /// body's `system` field (Claude's wire shape). Passed `inout` so the
    /// caller can substitute a content-block array when the plan asks for
    /// system caching — the plain-string form has no slot for
    /// `cache_control`.
    public func annotateCacheBreakpoints(
        plan: CacheBreakpointPlan,
        systemPrompt: String?,
        systemBlock: inout Any?,
        toolEntries: inout [[String: Any]]
    ) {
        guard case .claude = self else { return }
        #if CloudSaaS
        var remaining = plan.maxBreakpoints
        if plan.cacheSystem, remaining > 0, let systemPrompt, !systemPrompt.isEmpty {
            systemBlock = [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ] as [String: Any]
            ]
            remaining -= 1
        }
        if plan.cacheToolsTail, remaining > 0, !toolEntries.isEmpty {
            toolEntries[toolEntries.count - 1]["cache_control"] = ["type": "ephemeral"]
            remaining -= 1
        }
        #endif
    }

    // MARK: - Per-provider routing

    private var needsInlineSystemEntry: Bool {
        switch self {
        case .openAI, .openAIResponses: return true
        case .ollama: return true
        case .claude: return false // Claude routes system prompts via a top-level body field.
        }
    }

    private var supportsStructuredHistory: Bool {
        switch self {
        case .openAI, .claude: return true
        case .openAIResponses, .ollama: return false
        }
    }

    private func encodeStructuredMessage(_ message: StructuredMessage) -> [String: Any] {
        switch self {
        case .openAI:
            return Self.openAIEncodeChatCompletionsContent(for: message)
        case .claude:
            #if CloudSaaS
            return Self.claudeEncodeMessageContent(for: message)
            #else
            return ["role": message.role, "content": message.textContent]
            #endif
        case .openAIResponses, .ollama:
            // No structured-history support yet on these providers.
            return ["role": message.role, "content": message.textContent]
        }
    }

    private func encodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [[String: Any]] {
        switch self {
        case .openAI:
            #if CloudSaaS
            return [OpenAIToolEncoding.encodeChatCompletionsEntry(entry)]
            #else
            return [["role": entry.role, "content": entry.content]]
            #endif
        case .openAIResponses:
            #if CloudSaaS
            return OpenAIToolEncoding.encodeResponsesEntries(entry)
            #else
            return [["role": entry.role, "content": entry.content]]
            #endif
        case .claude:
            #if CloudSaaS
            return [Self.claudeEncodeToolAwareEntry(entry)]
            #else
            return [["role": entry.role, "content": entry.content]]
            #endif
        case .ollama:
            #if Ollama
            return [Self.ollamaEncodeToolAwareEntry(entry)]
            #else
            return [["role": entry.role, "content": entry.content]]
            #endif
        }
    }

    // MARK: - Convenience for callers still on the per-message API

    /// Encodes one ``StructuredMessage`` into the provider's content shape.
    /// Retained as a convenience for tests and call sites that build the
    /// message array piecewise; new code should prefer ``encodeMessages``.
    public func encodeStructuredMessageContent(for message: StructuredMessage) -> [String: Any] {
        encodeStructuredMessage(message)
    }
}

// MARK: - OpenAI Chat Completions inlined encoder

extension CloudMessageEncoder {

    /// Inlined from `OpenAIBackend.encodeChatCompletionsContent`. Encodes
    /// one ``StructuredMessage`` as a Chat Completions `messages[]` entry.
    /// Text-only turns collapse to plain string content; image-bearing
    /// user turns emit a structured `content[]` array.
    static func openAIEncodeChatCompletionsContent(for message: StructuredMessage) -> [String: Any] {
        let hasImage = message.parts.contains { part in
            if case .image = part { return true }
            return false
        }
        guard message.role == "user", hasImage else {
            return ["role": message.role, "content": message.textContent]
        }

        var contentParts: [[String: Any]] = []
        let text = message.textContent
        if !text.isEmpty {
            contentParts.append(["type": "text", "text": text])
        }
        for part in message.parts {
            if case .image(let data, let mimeType, _) = part {
                contentParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": CloudImageEncoding.dataURI(data: data, mimeType: mimeType),
                    ] as [String: Any],
                ])
            }
        }
        return ["role": "user", "content": contentParts]
    }
}

// MARK: - Claude (Anthropic Messages) inlined encoder

#if CloudSaaS
extension CloudMessageEncoder {

    /// Inlined from `ClaudeMessageEncoder.encodeMessageContent(for:)`.
    static func claudeEncodeMessageContent(for message: StructuredMessage) -> [String: Any] {
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
                    blocks.append(claudeEncodeImageBlock(data: data, mimeType: mimeType))
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
                    blocks.append(claudeEncodeImageBlock(data: data, mimeType: mimeType))
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

    /// Inlined from `ClaudeMessageEncoder.encodeImageBlock`.
    static func claudeEncodeImageBlock(data: Data, mimeType: String) -> [String: Any] {
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

    /// Inlined from `ClaudeMessageEncoder.encodeToolDefinition`.
    static func claudeEncodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
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

    /// Inlined from `ClaudeMessageEncoder.encodeToolAwareEntry`.
    static func claudeEncodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
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
                let inputObj = claudeDecodeArgumentsForReplay(call.arguments)
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

    /// Inlined from `ClaudeMessageEncoder.decodeArgumentsForReplay`.
    static func claudeDecodeArgumentsForReplay(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            return [:]
        }
        do {
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let object = decoded as? [String: Any] {
                return object
            }
            Log.inference.warning(
                "CloudMessageEncoder.claude: tool_use input parsed but is not a JSON object — substituting empty object to satisfy Anthropic schema."
            )
            return [:]
        } catch {
            Log.inference.warning(
                "CloudMessageEncoder.claude: tool_use input could not be re-parsed for replay — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }
}
#endif

// MARK: - Ollama inlined encoder

#if Ollama
extension CloudMessageEncoder {

    /// Inlined from `OllamaMessageEncoder.encodeToolDefinition`.
    static func ollamaEncodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let parameters = encodeJSONSchemaToFoundation(tool.parameters) {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return [
            "type": "function",
            "function": function,
        ]
    }

    /// Inlined from `OllamaMessageEncoder.encodeToolAwareEntry`.
    static func ollamaEncodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "role": entry.role,
            "content": entry.content,
        ]
        if let calls = entry.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map(Self.ollamaEncodeToolCall)
        }
        if let callId = entry.toolCallId {
            obj["tool_call_id"] = callId
        }
        return obj
    }

    /// Inlined from `OllamaMessageEncoder.encodeToolCall`.
    static func ollamaEncodeToolCall(_ call: ToolCall) -> [String: Any] {
        let argumentsValue: Any = ollamaParseArgumentString(call.arguments)
        return [
            "id": call.id,
            "type": "function",
            "function": [
                "name": call.toolName,
                "arguments": argumentsValue,
            ] as [String: Any],
        ]
    }

    /// Inlined from `OllamaMessageEncoder.parseArgumentString`.
    static func ollamaParseArgumentString(_ arguments: String) -> Any {
        guard let data = arguments.data(using: .utf8) else {
            Log.inference.warning(
                "CloudMessageEncoder.ollama: tool arguments string was not valid UTF-8 — substituting empty object in history."
            )
            return [String: Any]()
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            Log.inference.warning(
                "CloudMessageEncoder.ollama: tool arguments string was not valid JSON — substituting empty object in history. error=\(error.localizedDescription, privacy: .public)"
            )
            return [String: Any]()
        }
    }

    /// Applies ``GenerationConfig/toolChoice`` to an Ollama request body.
    /// Inlined from `OllamaMessageEncoder.applyToolChoice`.
    static func ollamaApplyToolChoice(_ choice: ToolChoice, into body: inout [String: Any]) {
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
#endif
