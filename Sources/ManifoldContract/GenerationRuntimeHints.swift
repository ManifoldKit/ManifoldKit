import Foundation

/// Per-request runtime hints that ride *alongside* ``GenerationConfig`` but are
/// deliberately **not** part of it.
///
/// These six fields are per-request, per-call inputs that must never be
/// persisted with a sampler preset. Keeping them on ``GenerationConfig`` forced
/// that type into a lossy `Codable` conformance — six fields silently dropped on
/// every encode/decode round-trip (the old "Codable round-trip is intentionally
/// lossy" apology). Extracting them here lets ``GenerationConfig`` become fully,
/// honestly `Codable`: every field it declares survives a round-trip.
///
/// `GenerationRuntimeHints` is intentionally **not** `Codable` — there is no
/// on-disk representation, so there is nothing to lose. Callers construct it per
/// request and thread it through the generation path next to the config:
///
/// ```swift
/// let stream = try backend.generate(
///     prompt: prompt,
///     systemPrompt: systemPrompt,
///     config: config,                       // persistable sampler settings
///     hints: GenerationRuntimeHints(        // per-request, never persisted
///         jsonMode: true,
///         thinkingMarkers: .qwen3
///     )
/// )
/// ```
///
/// Backends read the hints they honour directly (e.g. `LlamaBackend` and
/// `MLXBackend` read ``thinkingMarkers``; cloud backends read ``jsonMode`` and
/// ``structuredOutput``); hints a backend does not support are silently ignored,
/// exactly as the advisory fields on ``GenerationConfig`` are.
public struct GenerationRuntimeHints: Sendable, Equatable {

    /// Requests backend-specific JSON-object-only generation for this call.
    ///
    /// Backends that do not support structured output, or have not implemented
    /// JSON-mode wiring yet, silently ignore this flag. `GenerationQueue` emits
    /// an explicit warning when it is set against a backend whose
    /// ``BackendCapabilities/supportsNativeJSONMode`` is `false`.
    public var jsonMode: Bool

    /// Per-request override for the thinking-marker pair the backend should use
    /// to split reasoning tokens from visible output.
    ///
    /// - `nil` — let the backend use whatever it auto-detected when the model
    ///   was loaded (e.g. by reading the Jinja chat template). If auto-detection
    ///   also returned `nil`, no thinking parsing happens.
    /// - non-`nil` — overrides whatever the backend auto-detected.
    ///
    /// `GenerationQueue` emits an explicit warning when callers pass markers to a
    /// backend with ``BackendCapabilities/supportsThinking`` `== false`.
    public var thinkingMarkers: ThinkingMarkers?

    /// Routed structured-output strategy for this generation request.
    ///
    /// Callers can use ``StructuredOutputRouter`` to choose a strategy from
    /// backend capabilities, then pass it through here without forcing every
    /// backend to understand every representation.
    public var structuredOutput: StructuredOutputStrategy?

    /// Retrieved RAG passages threaded into a chat template's `documents`
    /// context variable (#1967).
    ///
    /// Only honoured by the prompt-template render path (embedded-Jinja): a
    /// template that exposes a `{% for document in documents %}` block formats
    /// these passages the way the model was trained to ground on. Empty (the
    /// default) keeps every `{% if documents %}` branch falsey.
    public var documents: [RetrievedDocument]

    /// Optional run-level token ceiling for a single tool-dispatch turn.
    ///
    /// Sibling to ``GenerationConfig/maxToolIterations``: where that bounds the
    /// *number* of tool round-trips, this bounds the cumulative token spend
    /// across them. The orchestrator accumulates prompt + completion tokens and,
    /// at the tool-iteration boundary, aborts the turn when the running total
    /// reaches this ceiling.
    ///
    /// - `nil` (the default) — no token ceiling.
    /// - non-`nil` — the cumulative token budget. Values `<= 0` disable the
    ///   ceiling (treated as no limit).
    public var maxRunTokens: Int?

    /// When `true`, the orchestration layer emits a
    /// ``GenerationEvent/promptRendered(text:)`` event as the first event in the
    /// generation stream, carrying the fully-assembled prompt string.
    ///
    /// Off by default (`false`) to avoid unintentional retention of sensitive
    /// prompt content. Only set this when you need to inspect or log the rendered
    /// prompt for debugging.
    public var captureRenderedPrompt: Bool

    /// Per-request override of how the prompt-template render path formats
    /// `messages` for a GGUF model whose embedded Jinja `tokenizer.chat_template`
    /// is present (#2200).
    ///
    /// Since 0.54 (#1898) an embedded chat template always wins over the
    /// hand-rolled ``PromptTemplate`` enum fallback — the render-honest default,
    /// and still the default here. But an honest instruct-tuned chat template
    /// pushes a model toward short, turn-bounded replies, which regresses
    /// long-form continuation use cases (story generation, prose completion)
    /// hard. Setting this to ``PromptRenderingMode/completion`` opts a single
    /// request into a plain-text continuation render instead — see
    /// ``PromptRenderingMode`` for the exact format and its tool-calling
    /// precedence rule.
    ///
    /// - `.chatTemplate` (the default) — unchanged behaviour: the embedded
    ///   Jinja template wins when present and renderable.
    /// - `.completion` — render `messages` as plain continuation text instead,
    ///   ignored (with a diagnostic) when `config.tools` is non-empty so tool
    ///   declarations are never silently dropped.
    public var renderingMode: PromptRenderingMode

    public init(
        jsonMode: Bool = false,
        thinkingMarkers: ThinkingMarkers? = nil,
        structuredOutput: StructuredOutputStrategy? = nil,
        documents: [RetrievedDocument] = [],
        maxRunTokens: Int? = nil,
        captureRenderedPrompt: Bool = false,
        renderingMode: PromptRenderingMode = .chatTemplate
    ) {
        self.jsonMode = jsonMode
        self.thinkingMarkers = thinkingMarkers
        self.structuredOutput = structuredOutput
        self.documents = documents
        self.maxRunTokens = maxRunTokens
        self.captureRenderedPrompt = captureRenderedPrompt
        self.renderingMode = renderingMode
    }
}

/// How the prompt-template render path should format a generation request
/// against a GGUF model that carries an embedded Jinja chat template (#2200).
///
/// This is the **only** layer this knob lives at — it rides on
/// ``GenerationRuntimeHints`` alongside the other per-request, never-persisted
/// fields (``GenerationRuntimeHints/jsonMode``, ``GenerationRuntimeHints/thinkingMarkers``,
/// …). It is deliberately **not** duplicated onto `GenerationConfig` or
/// `TurnConfig` — see the `TurnConfig`/`GenerationConfig` sampler-duplication
/// anti-pattern this project's API design policy calls out (docs/API-DESIGN.md).
/// A rendering-mode choice is a per-call, never-persisted decision exactly like
/// `jsonMode`, so it belongs where those already live, not on the persistable
/// sampler config.
public enum PromptRenderingMode: Sendable, Equatable {
    /// Render through the model's embedded Jinja chat template when one is
    /// present and usable (falling back to the hand-rolled ``PromptTemplate``
    /// enum otherwise) — unchanged 0.54+ behaviour, and the default.
    case chatTemplate

    /// Render `messages` as plain continuation text instead of through any
    /// chat template, even when an embedded template is present: `systemPrompt`
    /// (if any) followed by each message's textual content, in order, joined by
    /// blank lines — no role labels, no special tokens, and no trailing
    /// "assistant turn" delimiter. The model sees prose to continue, not a
    /// chat turn to answer.
    ///
    /// **Tool precedence**: when `GenerationConfig.tools` is non-empty for the
    /// same request, this override is ignored — the render path falls back to
    /// ``chatTemplate`` and a diagnostic is logged — rather than silently
    /// shipping a prompt with no tool declarations (mirrors the existing
    /// fail-fast precedent for unusable embedded templates in
    /// `PromptRenderer.render`).
    case completion
}
