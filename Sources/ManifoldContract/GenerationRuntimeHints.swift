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

    public init(
        jsonMode: Bool = false,
        thinkingMarkers: ThinkingMarkers? = nil,
        structuredOutput: StructuredOutputStrategy? = nil,
        documents: [RetrievedDocument] = [],
        maxRunTokens: Int? = nil,
        captureRenderedPrompt: Bool = false
    ) {
        self.jsonMode = jsonMode
        self.thinkingMarkers = thinkingMarkers
        self.structuredOutput = structuredOutput
        self.documents = documents
        self.maxRunTokens = maxRunTokens
        self.captureRenderedPrompt = captureRenderedPrompt
    }
}
