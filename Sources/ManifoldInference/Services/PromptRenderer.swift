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

    /// Renders `messages` into a single prompt string.
    ///
    /// - Parameters:
    ///   - messages: ordered `(role, content)` pairs.
    ///   - systemPrompt: optional system instruction.
    ///   - nativeTools: tools to render natively. Only consumed on the enum
    ///     fallback path (only `.gemma4` renders tools natively today); the
    ///     Jinja path receives tools via the host-folded system prompt, matching
    ///     the #1856 fold the queue already applies to non-native templates.
    func render(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        nativeTools: [ToolDefinition] = []
    ) -> String {
        if let chatTemplateRaw,
           let rendered = JinjaPromptRenderer.render(
               rawTemplate: chatTemplateRaw,
               messages: messages,
               systemPrompt: systemPrompt
           ) {
            return rendered
        }
        return template.format(messages: messages, systemPrompt: systemPrompt, tools: nativeTools)
    }
}
