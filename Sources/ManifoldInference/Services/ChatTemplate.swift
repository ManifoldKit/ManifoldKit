import Foundation

/// A typed value owning prompt formatting + the stop sequences a model's chat
/// format implies.
///
/// `ChatTemplate` wraps — it does not replace — the
/// `(PromptTemplate enum, chatTemplateRaw: String?)` pair that ``PromptRenderer``
/// has always taken. A template is one of two sources:
///
/// - ``Source/embeddedJinja(_:)`` — the model's real `tokenizer.chat_template`
///   Jinja string (rendered via ``JinjaPromptRenderer``), or
/// - ``Source/builtIn(_:)`` — the hand-rolled ``PromptTemplate`` enum fallback
///   for templateless models and for embedded templates `swift-jinja` cannot
///   evaluate (#1811).
///
/// For v1 (#1944) `ChatTemplate` is a thin, behaviour-preserving wrapper around
/// the existing render path: ``format(_:systemPrompt:tools:)`` delegates to a
/// ``PromptRenderer`` built from the same pair, then attaches the
/// template-derived ``stopSequences`` to the result. The public
/// ``PromptRenderer`` / ``PromptTemplate`` / ``ThinkingMarkers`` surface stays
/// exactly as it was — `ChatTemplate` is additive.
///
/// The eventual goal (deferred to a follow-up) is a public format protocol the
/// companion backend packages conform to; v1 only introduces the value and the
/// template-derived stop sequences so #1942's D2 has a home.
public struct ChatTemplate: Sendable {

    /// Where a template's formatting comes from.
    enum Source: Sendable {
        /// The model's embedded GGUF Jinja chat-template string.
        case embeddedJinja(String)
        /// The hand-rolled enum fallback.
        case builtIn(PromptTemplate)
    }

    let source: Source

    /// Wraps the hand-rolled enum fallback for a templateless model.
    public init(builtIn: PromptTemplate) {
        self.source = .builtIn(builtIn)
    }

    /// Wraps a model's embedded Jinja chat-template string.
    public init(embeddedJinja: String) {
        self.source = .embeddedJinja(embeddedJinja)
    }

    /// The thinking-marker pair this template advertises, or `nil` when the
    /// model does not emit reasoning blocks.
    ///
    /// - For ``Source/builtIn(_:)`` this delegates to
    ///   ``PromptTemplate/thinkingMarkers``.
    /// - For ``Source/embeddedJinja(_:)`` it runs
    ///   ``PromptTemplateDetector/detectThinkingMarkers(from:)`` over the raw
    ///   template string (the same detection the model-load path uses).
    public var thinkingMarkers: ThinkingMarkers? {
        switch source {
        case .builtIn(let template):
            return template.thinkingMarkers
        case .embeddedJinja(let raw):
            return PromptTemplateDetector.detectThinkingMarkers(from: raw)
        }
    }

    /// The turn-terminator stop sequences this template implies.
    ///
    /// These are the strings that, when emitted, signal the model has finished
    /// its turn — so a backend that honours stop strings can cut generation
    /// before leaking the next role's opening delimiter into the output.
    ///
    /// - For ``Source/builtIn(_:)`` this is a *curated* subset of the family's
    ///   turn-terminators (see ``builtInStopSequences(for:)``) — not the full
    ///   ``PromptTemplate`` special-token union, which also contains opening
    ///   delimiters that must NOT stop generation.
    /// - For ``Source/embeddedJinja(_:)`` this is `[]`: the embedded template
    ///   carries no machine-readable stop list, and parsing one out of Jinja is
    ///   deferred. Callers that need stops for an embedded-template model should
    ///   set ``GenerationConfig/stopSequences`` explicitly.
    public var stopSequences: [String] {
        switch source {
        case .builtIn(let template):
            return Self.builtInStopSequences(for: template)
        case .embeddedJinja:
            // Documented gap: no machine-readable stop list is extractable from
            // a raw Jinja string in v1.
            return []
        }
    }

    /// Renders `messages` into a ``RenderedPrompt`` — the prompt text plus the
    /// template-derived ``stopSequences``.
    ///
    /// Behaviour-preserving: the `text` is byte-identical to
    /// ``PromptRenderer/render(messages:systemPrompt:tools:documents:warnOnCapabilityLoss:)``
    /// for the same inputs. `ChatTemplate` only *adds* the stop-sequence channel.
    public func format(
        _ messages: [StructuredMessage],
        systemPrompt: String?,
        tools: [ToolDefinition]
    ) -> RenderedPrompt {
        let renderer: PromptRenderer
        switch source {
        case .builtIn(let template):
            renderer = PromptRenderer(template: template, chatTemplateRaw: nil)
        case .embeddedJinja(let raw):
            // Mirror the model-load detector so the enum fallback (when the
            // embedded template is unusable) lands on the right family.
            let fallback = PromptTemplateDetector.detect(fromChatTemplate: raw)
            renderer = PromptRenderer(template: fallback, chatTemplateRaw: raw)
        }
        let text = renderer.render(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )
        return RenderedPrompt(text: text, stopSequences: stopSequences)
    }

    /// Curated turn-terminator stop sequences per built-in family.
    ///
    /// Only *closing* / end-of-turn delimiters belong here — emitting one means
    /// "the assistant turn is over". Opening delimiters (`<|im_start|>`,
    /// `<|start_header_id|>`, role headers) are deliberately excluded: they are
    /// valid mid-prompt and would abort generation prematurely.
    static func builtInStopSequences(for template: PromptTemplate) -> [String] {
        switch template {
        case .chatML:
            return ["<|im_end|>"]
        case .llama3:
            return ["<|eot_id|>"]
        case .mistral:
            return ["</s>"]
        case .alpaca:
            // Alpaca has no special end token; the next section header is the
            // natural turn boundary.
            return ["### Instruction:", "### Input:"]
        case .gemma:
            return ["<end_of_turn>"]
        case .gemma4:
            return ["<|end_of_turn>"]
        case .phi:
            return ["<|end|>"]
        }
    }
}

/// The product of ``ChatTemplate/format(_:systemPrompt:tools:)`` — the rendered
/// prompt text plus the stop sequences the template implies.
public struct RenderedPrompt: Sendable {
    /// The fully-assembled prompt string ready for the backend.
    public let text: String

    /// The template-derived turn-terminator stop sequences. A backend may merge
    /// these with any caller-supplied ``GenerationConfig/stopSequences`` (caller
    /// overrides win).
    public let stopSequences: [String]

    public init(text: String, stopSequences: [String]) {
        self.text = text
        self.stopSequences = stopSequences
    }
}
