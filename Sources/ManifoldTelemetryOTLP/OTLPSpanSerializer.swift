import Foundation
import ManifoldInference

/// Serialises ``GenSpan`` values to the OTLP/JSON wire format.
///
/// Produces the `resourceSpans` envelope that the OpenTelemetry Collector,
/// Jaeger, Grafana Cloud, and any other OTLP/HTTP exporter endpoint expect.
/// The format follows the proto3 JSON mapping rules — `int64` values as quoted
/// strings, `double` and `bool` as JSON primitives.
///
/// Hosts POST the result of ``payload(for:)`` to `<collector>/v1/traces` with
/// `Content-Type: application/json`.
package enum OTLPSpanSerializer {

    // MARK: - Top-level envelope

    /// Returns the OTLP/JSON payload for a single span, encoded as `Data`.
    ///
    /// The payload is a `resourceSpans` envelope wrapping exactly one span.
    /// Callers that batch multiple spans should assemble the span objects
    /// themselves via ``spanObject(for:)`` and wrap in one envelope.
    package static func payload(for span: GenSpan) throws -> Data {
        let envelope = envelopeObject(spans: [spanObject(for: span)])
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    package static func envelopeObject(spans: [[String: Any]]) -> [String: Any] {
        [
            "resourceSpans": [
                [
                    "resource": resourceObject(),
                    "scopeSpans": [
                        [
                            "scope": [
                                "name": "ManifoldTelemetryOTLP",
                            ],
                            "spans": spans,
                        ]
                    ],
                ]
            ]
        ]
    }

    // MARK: - Span object

    package static func spanObject(for span: GenSpan) -> [String: Any] {
        var obj: [String: Any] = [
            "traceId": span.context.traceID.description,
            "spanId": span.context.spanID.description,
            "name": span.name,
            "kind": otlpKind(span.kind),
            "startTimeUnixNano": nanoString(span.start),
            "attributes": attributeArray(span),
            "status": statusObject(span.status),
        ]

        if let parentID = span.context.parentSpanID {
            obj["parentSpanId"] = parentID.description
        }
        if let end = span.end {
            obj["endTimeUnixNano"] = nanoString(end)
        }

        return obj
    }

    // MARK: - Helpers

    private static func resourceObject() -> [String: Any] {
        [
            "attributes": [
                kvString(key: "telemetry.sdk.name", value: "ManifoldKit"),
            ]
        ]
    }

    private static func attributeArray(_ span: GenSpan) -> [[String: Any]] {
        var pairs: [[String: Any]] = []

        // Inject OpenInference span kind first (canonical position).
        pairs.append(kvString(key: "openinference.span.kind", value: span.kind.openInferenceKind))

        for (key, value) in span.attributes.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .string(let s): pairs.append(kvString(key: key, value: s))
            case .int(let i):    pairs.append(kvInt(key: key, value: i))
            case .double(let d): pairs.append(kvDouble(key: key, value: d))
            case .bool(let b):   pairs.append(kvBool(key: key, value: b))
            }
        }

        return pairs
    }

    private static func statusObject(_ status: SpanStatus) -> [String: Any] {
        switch status {
        case .unset:
            return ["code": 0]
        case .ok:
            return ["code": 1]
        case .error(let msg):
            return ["code": 2, "message": msg]
        }
    }

    /// Maps ``SpanKind`` to the OTLP `SpanKind` integer.
    ///
    /// LLM and retriever spans use `SPAN_KIND_CLIENT` (3) per the OTel GenAI
    /// semantic conventions — they represent outbound calls to an external
    /// service. Orchestration (chain) and tool spans use `SPAN_KIND_INTERNAL`
    /// (1). Semantic meaning is additionally expressed through
    /// `openinference.span.kind` for tooling that reads that attribute.
    private static func otlpKind(_ kind: SpanKind) -> Int {
        switch kind {
        case .llm, .retriever: return 3   // SPAN_KIND_CLIENT
        case .tool, .chain, .other: return 1  // SPAN_KIND_INTERNAL
        }
    }

    private static func nanoString(_ date: Date) -> String {
        // Clamp to zero to avoid negative nanosecond strings for dates before
        // the Unix epoch (possible in tests that use fixed Date values).
        let nanos = max(0, date.timeIntervalSince1970) * 1_000_000_000
        return String(UInt64(nanos))
    }

    // MARK: - OTLP AnyValue constructors

    package static func kvString(key: String, value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    package static func kvInt(key: String, value: Int) -> [String: Any] {
        // Proto3 JSON mapping: int64 → quoted decimal string.
        ["key": key, "value": ["intValue": String(value)]]
    }

    package static func kvDouble(key: String, value: Double) -> [String: Any] {
        ["key": key, "value": ["doubleValue": value]]
    }

    package static func kvBool(key: String, value: Bool) -> [String: Any] {
        ["key": key, "value": ["boolValue": value]]
    }
}
