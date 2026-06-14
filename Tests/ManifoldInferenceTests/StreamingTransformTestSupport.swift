import ManifoldInference

/// Test shim that drives the new `ThinkingTransform` through the old
/// `ThinkingParser`-shaped API (`process(_ chunk: String)`), so the existing
/// `ThinkingParser*` regression suites keep exercising the unified transform
/// unchanged after the parser unification (#1593).
///
/// `ThinkingTransform.process` takes `[GenerationEvent]`; this wraps a raw chunk
/// as `[.token(chunk)]` — exactly what `OutputParserSession.ingest` does — and
/// forwards `finalize()` straight through.
struct ThinkingParser {
    private var transform: ThinkingTransform

    init(markers: ThinkingMarkers = .qwen3, trimLeadingNewlineAfterClose: Bool = false) {
        self.transform = ThinkingTransform(
            markers: markers,
            trimLeadingNewlineAfterClose: trimLeadingNewlineAfterClose
        )
    }

    var markers: ThinkingMarkers { transform.markers }

    mutating func process(_ chunk: String) -> [GenerationEvent] {
        transform.process([.token(chunk)])
    }

    mutating func finalize() -> [GenerationEvent] {
        transform.finalize()
    }
}
