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
    ///   actually references `tools` (a template that branches on it must name
    ///   it). The cheap textual probe is reliable: a template that renders tools
    ///   cannot do so without referencing the variable, and a stray mention only
    ///   costs a skipped preamble on a template that has no real tool block.
    /// - For templateless models, only the `.gemma4` enum renders tools natively.
    var rendersToolsNatively: Bool {
        if let chatTemplateRaw, !chatTemplateRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chatTemplateRaw.contains("tools")
        }
        return template.rendersToolsNatively
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
