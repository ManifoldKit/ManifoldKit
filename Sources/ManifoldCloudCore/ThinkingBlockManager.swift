import ManifoldInference

/// Tracks whether a streaming parser is currently inside a thinking block and
/// guarantees a single `.thinkingComplete` is emitted on the transition out.
///
/// Three SSE backends (`OpenAIBackend`, `ClaudeBackend`,
/// `OpenAIResponsesBackend`) all need the same primitive: "remember that we
/// yielded a `.thinkingToken`; the next non-thinking event — visible token,
/// upstream `reasoning_done`, stream end, or thrown error — must yield
/// `.thinkingComplete` exactly once before whatever comes next."
///
/// The state machine is intentionally minimal. Parsers keep their inline
/// event-extraction logic; this type only owns the open-state and the
/// `.thinkingComplete` emission so the close-rule is identical across
/// backends and survives refactors of the surrounding parsing code.
///
/// ```swift
/// var thinking = ThinkingBlockManager()
/// // ... saw a reasoning delta ...
/// continuation.yield(.thinkingToken(delta))
/// thinking.open()
/// // ... saw a visible-content delta ...
/// thinking.flushIfOpen(into: continuation)
/// continuation.yield(.token(delta))
/// // ... stream ended or threw ...
/// thinking.flushIfOpen(into: continuation)
/// ```
public struct ThinkingBlockManager {
    public private(set) var isOpen = false

    public init() {}

    /// Marks the thinking block as open. Idempotent: repeated calls without
    /// an intervening flush are a no-op (state stays open).
    public mutating func open() {
        isOpen = true
    }

    /// If a thinking block is currently open, yields a single
    /// `.thinkingComplete` and resets to closed. Otherwise a no-op.
    /// Idempotent — calling twice in a row yields at most one event.
    public mutating func flushIfOpen(into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        guard isOpen else { return }
        continuation.yield(.thinkingComplete)
        isOpen = false
    }
}
