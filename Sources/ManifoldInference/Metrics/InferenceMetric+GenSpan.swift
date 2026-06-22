import Foundation

extension Duration {
    /// Milliseconds as a `Double`, derived losslessly from the component
    /// representation. Used to populate latency attributes in fractional ms.
    fileprivate var inMilliseconds: Double {
        let c = components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
}

extension InferenceMetric {
    /// Adapts this flat metric into a vendor-neutral ``GenSpan`` of kind
    /// ``SpanKind/llm``.
    ///
    /// Lossless over the GenAI attribute set: every field on the metric is
    /// surfaced either as a span field (start/end/status) or a `gen_ai.*`
    /// attribute. This is the bridge that lets trace export work for hosts that
    /// never touch the new Run/Turn correlation IDs — pass a freshly-minted
    /// root context, or a child context built under a Turn span.
    ///
    /// - Parameters:
    ///   - context: The span context placing this generation in the trace tree.
    ///     Defaults to a fresh root span under a new trace.
    ///   - name: Span name; defaults to the model identifier.
    /// - Returns: A completed `.llm` span with start/end derived from
    ///   ``timestamp`` and ``wallClockDuration``.
    public func asGenSpan(
        context: SpanContext = .root(),
        name: String? = nil
    ) -> GenSpan {
        let end = timestamp.addingTimeInterval(wallClockDuration.inMilliseconds / 1_000)

        var attributes: [String: AttributeValue] = [
            GenAIAttributeKeys.system: .string(provider),
            GenAIAttributeKeys.requestModel: .string(model),
            GenAIAttributeKeys.usagePromptTokens: .int(promptTokens),
            GenAIAttributeKeys.usageCachedPromptTokens: .int(cachedPromptTokens),
            GenAIAttributeKeys.usageCompletionTokens: .int(completionTokens),
            GenAIAttributeKeys.timeToFirstTokenMs: .double(timeToFirstToken.inMilliseconds),
            GenAIAttributeKeys.meanInterTokenLatencyMs: .double(meanInterTokenLatency.inMilliseconds),
            GenAIAttributeKeys.wallClockMs: .double(wallClockDuration.inMilliseconds),
        ]

        let status: SpanStatus
        if let errorClass {
            attributes[GenAIAttributeKeys.errorType] = .string(errorClass)
            status = .error(errorClass)
        } else {
            status = .ok
        }

        return GenSpan(
            context: context,
            kind: .llm,
            name: name ?? model,
            start: timestamp,
            end: end,
            attributes: attributes,
            status: status
        )
    }
}
