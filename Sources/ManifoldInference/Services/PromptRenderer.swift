import Foundation

/// Single decision point for "how do we wrap chat messages into a prompt string
/// for a prompt-template backend?"
///
/// Prefers the model's *real* embedded GGUF Jinja chat template (rendered via
/// ``JinjaPromptRenderer``) when one is present and usable, falling back to the
/// hand-rolled ``PromptTemplate`` enum for templateless models — and for the
/// rare embedded template `swift-jinja` cannot evaluate (#1811).
///
/// Both the direct assembly path (``GenerationQueue``) and the exact-count
/// preflight trim loop (``GenerationPreflightTrimmer``) render through this type
/// so the token count and the prompt sent to the backend always agree.
struct PromptRenderer {

    /// The detected enum fallback. Always present — every model resolves to at
    /// least the ChatML default.
    let template: PromptTemplate

    /// The model's embedded `tokenizer.chat_template` Jinja string, or `nil` for
    /// templateless models. When present and renderable, it wins over `template`.
    let chatTemplateRaw: String?

    init(template: PromptTemplate, chatTemplateRaw: String?) {
        self.template = template
        self.chatTemplateRaw = chatTemplateRaw
    }

    /// Whether the prompt the executing path will produce renders tool
    /// definitions *natively* — i.e. the host must **not** also fold the
    /// ``ToolSystemPromptBuilder`` preamble into the system prompt, or the tools
    /// would be double-injected (#1856 / #1909).
    ///
    /// - When an embedded Jinja template is present, "native" means the template
    ///   references the `tools` *variable* inside a Jinja control/expression
    ///   block (`{%- if tools %}`, `{% for t in tools %}`, `{{ tools | tojson }}`).
    ///   A bare textual `.contains("tools")` is *not* sufficient: a template that
    ///   only mentions the word in static prose (e.g. a system message reading
    ///   "you have access to the following tools") or in literal output tokens
    ///   (`<|tools|>`) renders no tool block, yet a substring probe would mark it
    ///   native and skip the preamble — stranding the model with **zero** tool
    ///   guidance (the substring sees the prose, the template ignores the array).
    ///   Scoping the probe to Jinja-delimited regions keeps every genuine
    ///   tool-rendering template (which *must* reference the variable in control
    ///   flow) while rejecting prose/literal false positives.
    /// - For templateless models, only the `.gemma4` enum renders tools natively.
    var rendersToolsNatively: Bool {
        if let chatTemplateRaw, !chatTemplateRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.templateReferencesToolsVariable(chatTemplateRaw)
        }
        return template.rendersToolsNatively
    }

    /// Whether `template` references the `tools` variable inside a Jinja
    /// statement (`{% … %}`) or expression (`{{ … }}`) block — as opposed to a
    /// bare textual occurrence in static prose or literal output tokens.
    ///
    /// A template can only *render* the tool grammar by branching on or iterating
    /// the `tools` variable, which is always inside a Jinja delimiter pair. We
    /// scan only the delimited regions for the bare identifier `tools`
    /// (word-bounded, so `tool_calls` / `get_tools` / `<|tools|>` do not match)
    /// and ignore static prose entirely. This is a heuristic, not a full parse,
    /// but it cannot false-negative a template that genuinely renders tools.
    ///
    /// Implemented with a single forward scan rather than a regex so it stays off
    /// the `NSRegularExpression` allocation path on the hot prompt-render route.
    static func templateReferencesToolsVariable(_ template: String) -> Bool {
        let scalars = Array(template.unicodeScalars)
        var i = 0
        while i < scalars.count - 1 {
            // A Jinja block opens with `{%` (statement) or `{{` (expression).
            guard scalars[i] == "{", scalars[i + 1] == "%" || scalars[i + 1] == "{" else {
                i += 1
                continue
            }
            let closer: Unicode.Scalar = scalars[i + 1] == "%" ? "%" : "}"
            let blockStart = i + 2
            var j = blockStart
            // Find the matching closing delimiter (`%}` or `}}`). An unterminated
            // block runs to end-of-string — scan its tail as the final region.
            while j < scalars.count - 1, !(scalars[j] == closer && scalars[j + 1] == "}") {
                j += 1
            }
            let blockEnd = min(j, scalars.count) // exclusive
            if Self.scalarsContainToolsWord(scalars, from: blockStart, to: blockEnd) {
                return true
            }
            i = j + 2
        }
        return false
    }

    /// Whether `scalars[from..<to]` contains the bare identifier `tools` on
    /// identifier boundaries — i.e. not preceded or followed by an identifier
    /// scalar, so `tool_calls`, `get_tools`, and `toolset` do not match.
    private static func scalarsContainToolsWord(
        _ scalars: [Unicode.Scalar],
        from: Int,
        to: Int
    ) -> Bool {
        let word: [Unicode.Scalar] = ["t", "o", "o", "l", "s"]
        guard to - from >= word.count else { return false }
        var k = from
        while k <= to - word.count {
            if Array(scalars[k..<k + word.count]) == word {
                let prevIsIdent = k > from && Self.isIdentifierScalar(scalars[k - 1])
                let nextIndex = k + word.count
                let nextIsIdent = nextIndex < to && Self.isIdentifierScalar(scalars[nextIndex])
                if !prevIsIdent && !nextIsIdent { return true }
            }
            k += 1
        }
        return false
    }

    /// Jinja identifier scalars: letters, digits, and `_` (matching Python/Jinja
    /// name rules). Used to word-bound the `tools` probe.
    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        s == "_" || (s.properties.isAlphabetic) || ("0"..."9").contains(s)
    }

    /// Renders `messages` into a single prompt string.
    ///
    /// - Parameters:
    ///   - messages: the structured conversation history. The Jinja path threads
    ///     tool-call / tool-result structure into the template; the enum
    ///     fallback collapses to its text projection.
    ///   - systemPrompt: optional system instruction.
    ///   - tools: tool definitions to render. The Jinja path exposes them to the
    ///     template's `{% if tools %}` branch (#1909); the enum fallback consumes
    ///     them only for `.gemma4`. Callers pass the live `config.tools` array
    ///     unconditionally — ``rendersToolsNatively`` governs whether the host
    ///     *also* folds the preamble, so there is never a double injection.
    /// - Parameter warnOnCapabilityLoss: emit the one-line tool-drop /
    ///   multimodal-drop diagnostics (see ``warnIfCapabilityLost``). Defaults to
    ///   `true`. Callers that invoke `render` repeatedly for the *same* turn —
    ///   notably ``GenerationPreflightTrimmer``'s trim loop, which can render up
    ///   to 20 times before the prompt fits — pass `false` and emit the warning
    ///   exactly once instead, so an over-budget multimodal turn does not spam
    ///   the log with 20 identical lines.
    /// - Parameter documents: retrieved RAG passages exposed to an embedded
    ///   template's `{% for document in documents %}` block. The enum fallback
    ///   has no `documents` channel, so they are silently absent there — RAG
    ///   text still reaches that path through the system-prompt slot injection.
    func render(
        messages: [StructuredMessage],
        systemPrompt: String?,
        tools: [ToolDefinition] = [],
        documents: [RetrievedDocument] = [],
        warnOnCapabilityLoss: Bool = true
    ) -> String {
        if let chatTemplateRaw,
           let rendered = JinjaPromptRenderer.render(
               rawTemplate: chatTemplateRaw,
               messages: messages,
               systemPrompt: systemPrompt,
               tools: tools,
               documents: documents
           ) {
            if warnOnCapabilityLoss {
                warnIfCapabilityLost(messages: messages, tools: tools, viaEmbeddedTemplate: true)
            }
            return rendered
        }

        if warnOnCapabilityLoss {
            warnIfCapabilityLost(messages: messages, tools: tools, viaEmbeddedTemplate: false)
        }

        return template.format(
            messages: GenerationHistoryInstaller.flatten(messages),
            systemPrompt: systemPrompt,
            tools: tools
        )
    }

    /// Emits the capability-loss diagnostics for the render path that *would*
    /// run for `messages`/`tools` — the tool-drop warning when an unusable
    /// embedded template forces the text-only enum fallback, plus the
    /// multimodal-drop warning. Exposed so a caller that renders repeatedly for
    /// one turn (``GenerationPreflightTrimmer``) can warn once after the loop
    /// instead of on every attempt.
    ///
    /// `viaEmbeddedTemplate` reflects whether the *embedded Jinja* path produced
    /// the prompt; when `false` we additionally check for the silently-dropped
    /// tool definitions, since the enum path renders tools only for `.gemma4`.
    private func warnIfCapabilityLost(
        messages: [StructuredMessage],
        tools: [ToolDefinition],
        viaEmbeddedTemplate: Bool
    ) {
        // The enum fallback renders tools only for `.gemma4` and never renders
        // image/audio parts — so when the caller passed real tools (or
        // multimodal parts) and the fallback can't carry them, that capability
        // is being *silently dropped*. This is the exact shape behind the
        // recurring "tool-calling rate ~0% on model X" reports (#1909 / #1961):
        // fail loud so the loss is observable, not a mystery.
        if !viaEmbeddedTemplate, chatTemplateRaw != nil, !tools.isEmpty, !template.rendersToolsNatively {
            let fallbackName = String(describing: template)
            Log.inference.warning(
                "PromptRenderer: embedded chat template unusable; falling back to the \(fallbackName) text-only enum — \(tools.count) tool definition(s) will NOT be rendered into the prompt (expect degraded tool calling)."
            )
        }
        Self.warnIfMultimodalPartsDropped(messages, viaEmbeddedTemplate: viaEmbeddedTemplate)
    }

    /// Emits a one-line warning when the history carries `.image`/`.audio` parts
    /// that the prompt-string render path cannot express. Neither the embedded
    /// Jinja path (which threads only text / tool structure) nor the enum
    /// fallback renders multimodal parts into the prompt string; vision/audio
    /// backends receive those parts through the structured side-channel instead.
    /// A templated **text** model that is handed image parts will therefore
    /// silently ignore them — warn so that loss is visible.
    private static func warnIfMultimodalPartsDropped(
        _ messages: [StructuredMessage],
        viaEmbeddedTemplate: Bool
    ) {
        var images = 0
        var audio = 0
        for message in messages {
            for part in message.parts {
                switch part {
                case .image: images += 1
                case .audio: audio += 1
                default: break
                }
            }
        }
        guard images > 0 || audio > 0 else { return }
        let path = viaEmbeddedTemplate ? "embedded chat template" : "text-only enum fallback"
        Log.inference.warning(
            "PromptRenderer: \(images) image and \(audio) audio part(s) are not rendered into the prompt by the \(path) path; a text-only model will not see them."
        )
    }
}
