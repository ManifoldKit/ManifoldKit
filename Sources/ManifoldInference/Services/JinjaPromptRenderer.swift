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
    ///   - documents: retrieved RAG passages to expose to the template's
    ///     `{% if documents %}` / `{% for document in documents %}` branch. Empty
    ///     keeps that branch falsey. Each document is exposed with `title`/`text`
    ///     (the Command-R / HF RAG convention) plus a `doc_id` alias (#1967).
    ///   - errorSink: invoked with the underlying caught render error when the
    ///     template cannot be evaluated and `render` returns `nil`. Lets the
    ///     caller surface *why* the embedded template failed (e.g. an
    ///     alternation `raise_exception` from a Mistral-family template) in a
    ///     diagnostic message instead of swallowing it. Default `nil` keeps
    ///     every existing call site unchanged.
    /// - Returns: the rendered prompt, or `nil` when the template cannot be
    ///   parsed or evaluated. A `nil` return is the signal for the caller to
    ///   fall back to the ``PromptTemplate`` enum — never a hard failure, since
    ///   a malformed embedded template must not block generation.
    static func render(
        rawTemplate: String,
        messages: [StructuredMessage],
        systemPrompt: String?,
        tools: [ToolDefinition] = [],
        documents: [RetrievedDocument] = [],
        errorSink: ((Error) -> Void)? = nil
    ) -> String? {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Image parts are only folded into the per-message `content` list when
        // the template actually references images. Vision templates iterate
        // `message.content` as a list and branch on `content['type'] == 'image'`;
        // a text-only template expects `content` to be a plain string and
        // concatenates it (`+ message.content`), so injecting a content list
        // there would either break rendering or change the bytes a text model
        // sees. Probing once up front keeps the text path byte-identical (#1967).
        let threadImages = Self.templateReferencesImages(trimmed)

        // Only synthesize a leading system message when the host supplied one and
        // the history does not already open with a system turn. If the host gave
        // no system prompt, we deliberately omit it so the template's own
        // default-system branch (Qwen2.5 et al.) can fire.
        let historyHasLeadingSystem = messages.first?.role == "system"
        let prependsSystem: Bool
        if let systemPrompt, !systemPrompt.isEmpty, !historyHasLeadingSystem {
            prependsSystem = true
        } else {
            prependsSystem = false
        }

        var jinjaMessages: [[String: Any]] = []
        if prependsSystem, let systemPrompt {
            jinjaMessages.append(["role": "system", "content": systemPrompt])
        }
        for message in messages where renderableRoles.contains(message.role) {
            jinjaMessages.append(jinjaMessage(from: message, threadImages: threadImages))
        }

        do {
            return try renderJinja(
                trimmed: trimmed,
                jinjaMessages: jinjaMessages,
                tools: tools,
                documents: documents
            )
        } catch {
            // Render-retry for alternation-strict templates (#1992). Mistral-v0.3
            // (and other templates that assert `user`/`assistant` strictly
            // alternate from index 0) `raise_exception` on a leading `system`
            // turn. transformers handles this by folding the system instruction
            // into the FIRST user message rather than emitting a system turn.
            // We only reach here on the throwing path, so templates that ACCEPT a
            // leading system role never retry — their output is byte-identical to
            // before. Retry ONCE with the folded shape; if the host supplied no
            // system prompt or there is no user turn to fold into, there is
            // nothing to change, so fall through to the existing nil-return.
            if prependsSystem,
               let systemPrompt,
               let folded = Self.foldingSystemIntoFirstUser(
                   messages: messages,
                   systemPrompt: systemPrompt,
                   threadImages: threadImages
               ) {
                do {
                    return try renderJinja(
                        trimmed: trimmed,
                        jinjaMessages: folded,
                        tools: tools,
                        documents: documents
                    )
                } catch let retryError {
                    // The folded retry also failed — this template is genuinely
                    // unrenderable. Surface the retry error and fall through.
                    errorSink?(retryError)
                    Log.inference.warning(
                        "JinjaPromptRenderer: embedded chat template failed even after folding the system prompt into the first user turn, falling back to enum: \(retryError.localizedDescription)"
                    )
                    return nil
                }
            }

            // Do not crash generation on a malformed or unsupported embedded
            // template — log and let the caller fall back to the enum. This is a
            // recoverable boundary condition, not a programmer error.
            errorSink?(error)
            Log.inference.warning(
                "JinjaPromptRenderer: failed to render embedded chat template, falling back to enum: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Renders `jinjaMessages` against `trimmed`. Throws on a parse/evaluation
    /// failure (the signal the render-retry and enum-fallback paths key on) and
    /// — for symmetry with the empty-output miss — returns `nil` only via the
    /// empty-render branch, which is mapped to a thrown sentinel so a single
    /// `do/catch` covers both miss classes.
    private static func renderJinja(
        trimmed: String,
        jinjaMessages: [[String: Any]],
        tools: [ToolDefinition],
        documents: [RetrievedDocument]
    ) throws -> String {
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
            // Many templates also branch on `documents` (RAG retrieval).
            // Thread the retrieved passages through so `{% if documents %}`
            // fires for RAG turns; an empty array keeps it falsey rather than
            // raising an "undefined" error in stricter templates (#1967).
            "documents": try Value(any: documentsContext(documents)),
        ]
        let rendered = try template.render(context)
        // A template that evaluates to empty output is not usable — treat it
        // as a miss so the enum fallback produces a real prompt. Log it: an
        // empty render is otherwise a silent capability loss (the caller
        // degrades to the text-only enum), the same failure class as the
        // catch branch in `render`.
        if rendered.isEmpty {
            Log.inference.warning(
                "JinjaPromptRenderer: embedded chat template rendered empty output, falling back to enum."
            )
            throw EmptyRenderError()
        }
        return rendered
    }

    /// Sentinel thrown when a template evaluates to empty output, so the
    /// single `do/catch` in `render` treats it as a render miss. (It never
    /// reaches the retry's fold path usefully — folding a system prompt into a
    /// user turn does not make an empty-output template produce text — so the
    /// retry simply re-misses and falls through, exactly as before.)
    private struct EmptyRenderError: Error {}

    /// Builds the `jinjaMessages` array WITHOUT a synthesized `system` turn,
    /// folding `systemPrompt` into the first user message's content as
    /// `systemPrompt + "\n\n" + originalFirstUserContent`. Returns `nil` when
    /// there is no user turn to fold into (nothing to retry).
    ///
    /// This mirrors `transformers.apply_chat_template`'s handling of
    /// alternation-strict templates (Mistral-v0.3 et al.) that reject a leading
    /// system role.
    private static func foldingSystemIntoFirstUser(
        messages: [StructuredMessage],
        systemPrompt: String,
        threadImages: Bool
    ) -> [[String: Any]]? {
        let renderable = messages.filter { renderableRoles.contains($0.role) }
        guard let firstUserIndex = renderable.firstIndex(where: { $0.role == "user" }) else {
            return nil
        }
        var jinjaMessages: [[String: Any]] = []
        for (index, message) in renderable.enumerated() {
            var dict = jinjaMessage(from: message, threadImages: threadImages)
            if index == firstUserIndex {
                let original = message.textContent
                let merged = original.isEmpty ? systemPrompt : systemPrompt + "\n\n" + original
                // Only override a plain-string content; if this user turn already
                // carries an image content-list, prepend the system text as a
                // leading text block instead of clobbering the list.
                if let list = dict["content"] as? [[String: Any]] {
                    var newList: [[String: Any]] = [["type": "text", "text": merged]]
                    newList.append(contentsOf: list.filter { ($0["type"] as? String) != "text" || ($0["text"] as? String) != original })
                    dict["content"] = newList
                } else {
                    dict["content"] = merged
                }
            }
            jinjaMessages.append(dict)
        }
        return jinjaMessages
    }

    /// Builds the per-message Jinja dictionary, threading the native tool-call /
    /// tool-result structure that the text-only projection used to drop (#1909).
    ///
    /// When `threadImages` is true and the message carries `.image` parts, the
    /// `content` is emitted as a *list* of typed blocks (the HF/Qwen-VL vision
    /// convention) instead of a plain string, so a vision template's image
    /// placeholder branches fire (#1967). Otherwise `content` stays a plain
    /// string and the text path is byte-identical to the pre-#1967 behaviour.
    private static func jinjaMessage(
        from message: StructuredMessage,
        threadImages: Bool
    ) -> [String: Any] {
        let imageParts: [(data: Data, mimeType: String)] = message.parts.compactMap { part in
            guard case .image(let data, let mimeType, _) = part else { return nil }
            return (data, mimeType)
        }

        var dict: [String: Any] = [
            "role": message.role,
            "content": message.textContent,
        ]

        // Vision content-list shape. Only when the template references images AND
        // this turn actually carries image bytes — otherwise leave `content` as
        // the plain string the text path expects.
        if threadImages, !imageParts.isEmpty {
            dict["content"] = imageContentList(text: message.textContent, images: imageParts)
        }

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
            // result content in as the message content when text is absent or
            // empty. Guard against clobbering an already-set content-list
            // (e.g. images threaded above): only overwrite when `content` is
            // literally an empty string or nil, not when it is already a list.
            switch dict["content"] {
            case nil:
                dict["content"] = result.content
            case let s as String where s.isEmpty:
                dict["content"] = result.content
            default:
                break
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

    // MARK: - Image threading (#1967)

    /// Builds the multimodal `content` list a vision chat template iterates.
    ///
    /// Mirrors the cloud reference path (`CloudMessageEncoder`): a leading text
    /// block (when the turn has visible text) followed by one block per image.
    /// Each image block carries both shapes so templates written against either
    /// convention resolve — `type: "image"` with an `image_url.url` data URI
    /// (the OpenAI/HF Chat-Completions shape) and a flat `image` alias holding
    /// the same data URI (gemma/Qwen-VL templates that read `content['image']`).
    /// The payload itself is the identical base64 `data:` URI cloud backends
    /// emit (`CloudImageEncoding.dataURI`), so vision producers and the local
    /// render path agree on the byte shape.
    private static func imageContentList(
        text: String,
        images: [(data: Data, mimeType: String)]
    ) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for image in images {
            let uri = dataURI(data: image.data, mimeType: image.mimeType)
            blocks.append([
                "type": "image",
                "image_url": ["url": uri] as [String: Any],
                // Flat alias for templates that read `content['image']` directly.
                "image": uri,
            ])
        }
        return blocks
    }

    /// Returns a `data:` URI (RFC 2397) for the image bytes — `data:<mime>;base64,<payload>`.
    ///
    /// Reproduces ``CloudImageEncoding/dataURI(data:mimeType:)`` (which lives in
    /// `ManifoldCloudCore`, a module that depends on this one, so it cannot be
    /// imported here) so the local Jinja path and the cloud backends shape the
    /// image payload identically.
    private static func dataURI(data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Whether `template` references the bare `image` identifier inside a Jinja
    /// statement/expression block — the only way a template can render an image
    /// placeholder. Mirrors ``PromptRenderer/templateReferencesToolsVariable(_:)``:
    /// scan only the delimited regions for the word-bounded identifier so
    /// `image_url` / `generatedImage` / static prose do not false-positive.
    static func templateReferencesImages(_ template: String) -> Bool {
        let scalars = Array(template.unicodeScalars)
        var i = 0
        while i < scalars.count - 1 {
            guard scalars[i] == "{", scalars[i + 1] == "%" || scalars[i + 1] == "{" else {
                i += 1
                continue
            }
            let closer: Unicode.Scalar = scalars[i + 1] == "%" ? "%" : "}"
            let blockStart = i + 2
            var j = blockStart
            while j < scalars.count - 1, !(scalars[j] == closer && scalars[j + 1] == "}") {
                j += 1
            }
            let blockEnd = min(j, scalars.count)
            if scalarsContainWord(["i", "m", "a", "g", "e"], in: scalars, from: blockStart, to: blockEnd) {
                return true
            }
            i = j + 2
        }
        return false
    }

    /// Whether `scalars[from..<to]` contains `word` on identifier boundaries
    /// (`image_url`, `images` do not match the bare `image` probe). Shares the
    /// boundary rule with ``PromptRenderer``'s tools scan.
    private static func scalarsContainWord(
        _ word: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        from: Int,
        to: Int
    ) -> Bool {
        guard to - from >= word.count else { return false }
        var k = from
        while k <= to - word.count {
            if Array(scalars[k..<k + word.count]) == word {
                let prevIsIdent = k > from && isIdentifierScalar(scalars[k - 1])
                let nextIndex = k + word.count
                let nextIsIdent = nextIndex < to && isIdentifierScalar(scalars[nextIndex])
                if !prevIsIdent && !nextIsIdent { return true }
            }
            k += 1
        }
        return false
    }

    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        s == "_" || s.properties.isAlphabetic || ("0"..."9").contains(s)
    }

    // MARK: - RAG documents threading (#1967)

    /// Converts retrieved RAG passages into the template-facing `documents`
    /// context. Each document carries `title`/`text` — the Command-R / HF RAG
    /// convention every `{% for document in documents %}` template reads — plus
    /// a `doc_id` alias (Command-R's grounded-generation templates index by it)
    /// derived from the document's 1-based position when the source has none.
    private static func documentsContext(_ documents: [RetrievedDocument]) -> [[String: Any]] {
        documents.enumerated().map { index, document in
            [
                "doc_id": document.docID ?? String(index),
                "title": document.title,
                "text": document.text,
            ]
        }
    }
}
