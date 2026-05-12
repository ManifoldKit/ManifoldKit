/// Controls whether Anthropic prompt-cache breakpoints are emitted in outbound requests.
///
/// Anthropic charges full input-token rates on every turn unless blocks are
/// tagged with `cache_control: {type: "ephemeral"}`. Enabling caching here
/// inserts those markers at the system-prompt block and the last tool definition
/// so the prefix is priced at cache-read rates on subsequent turns — typically
/// a 4–10× cost reduction for conversations with large system prompts or tool
/// catalogs. See https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching.
public enum PromptCachePolicy: Sendable {
    /// No `cache_control` markers emitted. Matches pre-0.25.0 behaviour.
    case disabled
    /// Tag the system prompt block and the last tool definition with
    /// `cache_control: {type: "ephemeral"}`. Default for ``ClaudeBackend``.
    case automatic
}
