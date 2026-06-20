import Foundation

// MARK: - Identifiers

/// A 128-bit trace identifier shared by every span in a single Run.
///
/// Vendor-neutral by design: maps directly onto an OpenTelemetry `trace_id`
/// (16 bytes) and onto OpenInference's trace correlation, but carries no
/// dependency on either library. Hosts that link an OTLP exporter serialise
/// the raw bytes; tests and in-memory sinks compare by value.
public struct TraceID: Sendable, Hashable, CustomStringConvertible {
    /// 16 raw bytes (128 bits), big-endian, matching the OTLP wire format.
    public let bytes: [UInt8]

    /// Wraps an explicit 16-byte identifier.
    /// - Parameter bytes: Exactly 16 bytes. Shorter/longer arrays are accepted
    ///   verbatim so callers controlling their own encoding are never blocked,
    ///   but ``random()`` is the supported way to mint a conformant ID.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Mints a cryptographically-random 128-bit trace ID.
    public static func random() -> TraceID {
        TraceID(bytes: (0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Lowercase hex, the canonical OTLP/OpenInference string form.
    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A 64-bit span identifier, unique within a Run.
///
/// Maps onto an OpenTelemetry `span_id` (8 bytes). See ``TraceID`` for the
/// vendor-neutrality rationale.
public struct SpanID: Sendable, Hashable, CustomStringConvertible {
    /// 8 raw bytes (64 bits), big-endian, matching the OTLP wire format.
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Mints a cryptographically-random 64-bit span ID.
    public static func random() -> SpanID {
        SpanID(bytes: (0..<8).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Lowercase hex, the canonical OTLP/OpenInference string form.
    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Identifies a span and links it to its parent within a trace.
///
/// The `(traceID, spanID, parentSpanID)` triple is the minimal correlation
/// structure needed to reconstruct a Run → Turn → span tree. A `nil`
/// `parentSpanID` marks a trace root (typically the Run span).
public struct SpanContext: Sendable, Hashable {
    public let traceID: TraceID
    public let spanID: SpanID
    public let parentSpanID: SpanID?

    public init(traceID: TraceID, spanID: SpanID, parentSpanID: SpanID? = nil) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }

    /// Creates a root span context (no parent) under a fresh or supplied trace.
    public static func root(traceID: TraceID = .random()) -> SpanContext {
        SpanContext(traceID: traceID, spanID: .random(), parentSpanID: nil)
    }

    /// Creates a child context that inherits this span's trace and points its
    /// `parentSpanID` back at the receiver.
    public func child(spanID: SpanID = .random()) -> SpanContext {
        SpanContext(traceID: traceID, spanID: spanID, parentSpanID: self.spanID)
    }
}

// MARK: - Span shape

/// The semantic role of a span, aligned with OpenInference `span.kind` /
/// OTel GenAI conventions but expressed vendor-neutrally.
public enum SpanKind: Sendable, Hashable {
    /// A multi-turn Run / agent loop (OpenInference `CHAIN`).
    case chain
    /// A single model generation call (OpenInference `LLM`).
    case llm
    /// A single tool invocation within a turn (OpenInference `TOOL`).
    case tool
    /// A retrieval / RAG step.
    case retriever
    /// Anything not covered above; `raw` is the exporter-facing kind string.
    case other(String)

    /// The OpenInference `openinference.span.kind` string for this kind.
    public var openInferenceKind: String {
        switch self {
        case .chain: return "CHAIN"
        case .llm: return "LLM"
        case .tool: return "TOOL"
        case .retriever: return "RETRIEVER"
        case .other(let raw): return raw
        }
    }
}

/// A span's terminal status.
public enum SpanStatus: Sendable, Hashable {
    case unset
    case ok
    /// Failure; the associated value is the short error class (e.g.
    /// "rateLimited"), mapped from ``InferenceMetric/errorClass``.
    case error(String)
}

/// A vendor-neutral attribute value.
///
/// Deliberately small: the GenAI attribute set is strings, ints, doubles, and
/// bools. Keeping the enum closed lets exporters switch exhaustively without an
/// `Any`-typed escape hatch.
public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// A vendor-neutral span over the GenAI Run → Turn → span tree.
///
/// Maps cleanly to OpenInference / OTel GenAI conventions without importing
/// either: an exporter product (kept out of core and the umbrella) serialises
/// these to OTLP. The in-tree ``RecordingTraceSink`` collects them for tests
/// and diagnostics.
public struct GenSpan: Sendable {
    public let context: SpanContext
    public let kind: SpanKind
    public let name: String
    public let start: Date
    public var end: Date?
    public var attributes: [String: AttributeValue]
    public var status: SpanStatus

    public init(
        context: SpanContext,
        kind: SpanKind,
        name: String,
        start: Date,
        end: Date? = nil,
        attributes: [String: AttributeValue] = [:],
        status: SpanStatus = .unset
    ) {
        self.context = context
        self.kind = kind
        self.name = name
        self.start = start
        self.end = end
        self.attributes = attributes
        self.status = status
    }
}

// MARK: - Well-known attribute keys

/// Canonical GenAI attribute keys, matching the OTel GenAI semantic
/// conventions. Centralised so the adapter and any exporter agree on spelling.
public enum GenAIAttributeKeys {
    public static let system = "gen_ai.system"
    public static let requestModel = "gen_ai.request.model"
    public static let usagePromptTokens = "gen_ai.usage.prompt_tokens"
    public static let usageCachedPromptTokens = "gen_ai.usage.cached_prompt_tokens"
    public static let usageCompletionTokens = "gen_ai.usage.completion_tokens"
    /// Non-standard but widely-ingested: per-call estimated cost in USD.
    public static let costUSD = "gen_ai.usage.cost_usd"
    public static let costApproximate = "gen_ai.usage.cost_is_approximate"
    public static let costTableDate = "gen_ai.usage.cost_table_date"
    /// Time-to-first-token in milliseconds.
    public static let timeToFirstTokenMs = "gen_ai.latency.time_to_first_token_ms"
    /// Mean inter-token latency in milliseconds.
    public static let meanInterTokenLatencyMs = "gen_ai.latency.mean_inter_token_ms"
    /// Wall-clock call duration in milliseconds.
    public static let wallClockMs = "gen_ai.latency.wall_clock_ms"
    public static let errorType = "error.type"
}
