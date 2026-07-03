/// Token-usage accounting reported by an inference backend, carried by
/// ``GenerationEvent/usage(_:)``.
///
/// ## Growth point for future token accounting
///
/// This is deliberately a `struct` payload rather than bare enum associated
/// values (the way ``ToolProgressEvent`` is). The `GenerationEvent` enum is
/// frozen as of the 1.0 release, but token accounting is a near-certain growth
/// area: providers are beginning to report cached-prompt tokens, reasoning
/// (thinking) tokens, and tool-overhead tokens separately. Modelling usage as a
/// struct lets those fields arrive later as **defaulted** initializer
/// parameters — additive, source-compatible, and invisible to any consumer that
/// already pattern-matches `.usage(let usage)`. A bare-parameter case
/// (`case usage(prompt:completion:)`) could not grow that way without breaking
/// every exhaustive `switch`.
///
/// When adding a field, give it a default in the memberwise init so existing
/// `TokenUsage(promptTokens:completionTokens:)` call sites keep compiling.
public struct TokenUsage: Sendable, Equatable, Hashable {
    /// Number of prompt (input) tokens the backend reported for this request.
    public let promptTokens: Int

    /// Number of completion (output) tokens the backend reported for this
    /// request.
    public let completionTokens: Int

    /// Tokens served from a provider's prompt cache on this request
    /// (Anthropic: `cache_read_input_tokens`). `nil` for backends that don't
    /// report prompt-cache metrics — distinct from a reported `0`.
    public let cachedInputTokens: Int?

    /// Tokens written to a provider's prompt cache on this request
    /// (Anthropic: `cache_creation_input_tokens`). `nil` for backends that
    /// don't report prompt-cache metrics — distinct from a reported `0`.
    public let cacheWriteTokens: Int?

    public init(
        promptTokens: Int,
        completionTokens: Int,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}
