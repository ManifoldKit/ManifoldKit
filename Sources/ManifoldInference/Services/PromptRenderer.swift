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
    func render(
        messages: [StructuredMessage],
        systemPrompt: String?,
        tools: [ToolDefinition] = []
    ) -> String {
        if let chatTemplateRaw,
           let rendered = JinjaPromptRenderer.render(
               rawTemplate: chatTemplateRaw,
               messages: messages,
               systemPrompt: systemPrompt,
               tools: tools
           ) {
            return rendered
        }
        return template.format(
            messages: GenerationHistoryInstaller.flatten(messages),
            systemPrompt: systemPrompt,
            tools: tools
        )
    }
}
