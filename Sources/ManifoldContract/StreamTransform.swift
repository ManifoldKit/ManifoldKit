/// A single stage in an ``OutputParserSession`` pipeline.
///
/// Each transform consumes a batch of `[GenerationEvent]`, re-scans **only the
/// `.token` payloads** against its own markers, and passes every other event
/// case (`.thinkingToken`, `.thinkingCompleted`, `.toolCall`, usage, lifecycle,
/// …) straight through untouched. This is the composition contract that lets
/// the drivers chain a thinking stage and a tool-call stage in either order:
/// the upstream stage's structured output is never re-interpreted downstream,
/// only its still-plain `.token` text is.
///
/// `finalize()` flushes any bytes the transform is holding back at the chunk
/// boundary — an unterminated marker resolves to plain text (or thinking text),
/// and a dangling open tool block is discarded.
public protocol StreamTransform: Sendable {
    /// Re-scan the `.token` payloads in `events`; pass all other cases through.
    mutating func process(_ events: [GenerationEvent]) -> [GenerationEvent]

    /// Flush held-back state at stream end. Call once after the generation loop.
    mutating func finalize() -> [GenerationEvent]
}

/// The concrete stages an ``OutputParserSession`` can hold.
///
/// Modeled as an `enum` rather than `[any StreamTransform]` deliberately: with
/// exactly two concrete transforms there is no need for existential boxing.
/// The enum keeps `Sendable` conformance trivial (both payloads are `Sendable`
/// value types), avoids per-event `any`-witness dispatch on the streaming hot
/// path, and makes the closed set of stages explicit at the type level.
public enum Stage: Sendable {
    case thinking(ThinkingTransform)
    case tool(ToolCallTransform)

    mutating func process(_ events: [GenerationEvent]) -> [GenerationEvent] {
        switch self {
        case .thinking(var t):
            let out = t.process(events)
            self = .thinking(t)
            return out
        case .tool(var t):
            let out = t.process(events)
            self = .tool(t)
            return out
        }
    }

    mutating func finalize() -> [GenerationEvent] {
        switch self {
        case .thinking(var t):
            let out = t.finalize()
            self = .thinking(t)
            return out
        case .tool(var t):
            let out = t.finalize()
            self = .tool(t)
            return out
        }
    }
}
