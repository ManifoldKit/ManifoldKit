/// An ordered chain of streaming output transforms.
///
/// Replaces the hand-rolled two-stage parser pipelines that each backend driver
/// used to wire up by hand (`MLXToolCallParser` → `ThinkingParser` for MLX;
/// `ThinkingParser` → `LlamaToolCallParser` for Llama). The backend supplies
/// the ordered stages as configuration; the session owns the per-chunk piping
/// and the end-of-stream finalize cascade.
///
/// ## Stage order is chain order
///
/// Each chunk flows through the stages **in declaration order**, and every
/// stage re-scans only the `.token` payloads it receives — structured output a
/// prior stage produced (`.thinkingToken`, `.toolCall`, …) passes through
/// downstream stages untouched. So the order maps directly to "what does each
/// dialect see first":
///
/// | Backend | Stages | Rationale |
/// |---------|--------|-----------|
/// | MLX     | `[.tool, .thinking]` | tool tags are stripped first, then thinking re-scans the remaining visible text. Preserves MLX's historical order — zero behavior change. |
/// | Llama   | `[.thinking, .tool]` | thinking is stripped first; tool calls never appear inside a thinking block, so the tool stage only sees post-thinking visible text. |
/// | Ollama  | `[.thinking]` | content-field scan only; Ollama tool calls arrive via structured fields, not raw text. |
///
/// ## N-candidate tool dialects
///
/// A single ``ToolCallTransform`` stage can carry several `ToolCallMarker`
/// dialects and resolves them earliest-open-wins (ties → array order). That is
/// how Llama folds its two competing open tags (`<|tool_call>` and
/// `<tool_call>`) into one stage.
///
/// ## Finalize discard rule
///
/// `finalize()` flushes each stage's held-back tail in chain order and feeds
/// every flushed event into the downstream stages' `process` before they
/// finalize in turn. An unterminated thinking block flushes as `.thinkingToken`;
/// a trailing partial open tag flushes as plain `.token`; an unterminated open
/// **tool** block is discarded — partial body text cannot form a valid
/// `ToolCall`.
public struct OutputParserSession {
    private var stages: [Stage]

    public init(_ stages: [Stage]) {
        self.stages = stages
    }

    /// Feed a raw text chunk through the chain.
    ///
    /// The chunk is wrapped as `[.token(chunk)]` and piped through each stage in
    /// order. Returns the fully-transformed events for this chunk.
    public mutating func ingest(_ chunk: String) -> [GenerationEvent] {
        var events: [GenerationEvent] = [.token(chunk)]
        for index in stages.indices {
            events = stages[index].process(events)
        }
        return events
    }

    /// Flush all stages at stream end, cascading each stage's tail through the
    /// stages downstream of it.
    ///
    /// For stage *i* (in order): finalize it, then `process` its flushed events
    /// through every stage after it. This guarantees that, for example, text a
    /// thinking stage releases at finalize is still scanned by a downstream tool
    /// stage before that tool stage finalizes — no released text bypasses a
    /// later stage's transform.
    public mutating func finalize() -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        for i in stages.indices {
            var flushed = stages[i].finalize()
            for j in stages.indices where j > i {
                flushed = stages[j].process(flushed)
            }
            out += flushed
        }
        return out
    }
}
