import XCTest
@testable import ManifoldInference

/// Unit tests for the vendor-neutral GenAI trace abstraction: the
/// ``InferenceMetric`` → ``GenSpan`` adapter, span-tree correlation, and the
/// in-memory ``RecordingTraceSink``. No SwiftData, no live collector.
final class TraceSinkTests: XCTestCase {

    private func metric(
        provider: String = "Claude",
        model: String = "claude-sonnet-4-6",
        promptTokens: Int = 120,
        cachedPromptTokens: Int = 40,
        completionTokens: Int = 256,
        errorClass: String? = nil
    ) -> InferenceMetric {
        InferenceMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            timeToFirstToken: .milliseconds(180),
            meanInterTokenLatency: .milliseconds(12),
            wallClockDuration: .milliseconds(900),
            errorClass: errorClass,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: - Adapter

    func test_metricAdapter_isLosslessOverGenAIAttributes() throws {
        let m = metric()
        let span = m.asGenSpan()

        XCTAssertEqual(span.kind, .llm)
        XCTAssertEqual(span.name, m.model)
        XCTAssertEqual(span.start, m.timestamp)
        XCTAssertEqual(span.status, .ok)

        XCTAssertEqual(span.attributes[GenAIAttributeKeys.system], .string("Claude"))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.requestModel], .string("claude-sonnet-4-6"))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.usagePromptTokens], .int(120))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.usageCachedPromptTokens], .int(40))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.usageCompletionTokens], .int(256))
        // Latency attributes carry millisecond values.
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.timeToFirstTokenMs], .double(180))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.meanInterTokenLatencyMs], .double(12))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.wallClockMs], .double(900))

        // end = start + wallClock (900ms).
        let end = try XCTUnwrap(span.end)
        XCTAssertEqual(end.timeIntervalSince1970, 1_000_000.9, accuracy: 0.001)
    }

    func test_erroredMetric_setsErrorStatusAndType() {
        let span = metric(errorClass: "rateLimited").asGenSpan()
        XCTAssertEqual(span.status, .error("rateLimited"))
        XCTAssertEqual(span.attributes[GenAIAttributeKeys.errorType], .string("rateLimited"))
    }

    // MARK: - Single generation span

    func test_singleGeneration_emitsOneLLMSpan() async {
        let sink = RecordingTraceSink()
        await sink.record(metric().asGenSpan())

        let spans = await sink.recordedSpans()
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .llm)
        XCTAssertNil(spans.first?.context.parentSpanID, "A bare generation span is a trace root.")
    }

    // MARK: - Tool-loop turn tree

    func test_toolLoopTurn_emitsRunTurnLLMToolLLMTree() async {
        let sink = RecordingTraceSink()

        let (runSpan, runCtx) = GenSpanTree.run()
        let (turnSpan, turnCtx) = GenSpanTree.turn(under: runCtx)
        let llm1 = GenSpanTree.generation(metric(), under: turnCtx)
        let (toolSpan, _) = GenSpanTree.tool(under: turnCtx, name: "get_weather")
        let llm2 = GenSpanTree.generation(metric(completionTokens: 64), under: turnCtx)

        for s in [runSpan, turnSpan, llm1, toolSpan, llm2] { await sink.record(s) }

        // One trace shared by all spans.
        let traceID = runCtx.traceID
        let allSpans = await sink.recordedSpans()
        XCTAssertTrue(allSpans.allSatisfy { $0.context.traceID == traceID })

        // Run is the sole root.
        let roots = await sink.roots(in: traceID)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.kind, .chain)

        // Turn is the Run's only child.
        let runChildren = await sink.children(of: runCtx.spanID)
        XCTAssertEqual(runChildren.map(\.context.spanID), [turnCtx.spanID])

        // Turn has exactly three children: llm, tool, llm in order.
        let turnChildren = await sink.children(of: turnCtx.spanID)
        XCTAssertEqual(turnChildren.map(\.kind), [.llm, .tool, .llm])
        XCTAssertEqual(
            turnChildren.map(\.context.spanID),
            [llm1.context.spanID, toolSpan.context.spanID, llm2.context.spanID]
        )

        // Every child correctly parents back to the Turn.
        XCTAssertTrue(turnChildren.allSatisfy { $0.context.parentSpanID == turnCtx.spanID })
    }

    func test_childContext_inheritsTraceAndLinksParent() {
        let root = SpanContext.root()
        let child = root.child()
        XCTAssertEqual(child.traceID, root.traceID)
        XCTAssertEqual(child.parentSpanID, root.spanID)
        XCTAssertNotEqual(child.spanID, root.spanID)
    }

    func test_traceID_hexIsThirtyTwoChars() {
        XCTAssertEqual(TraceID.random().description.count, 32)
        XCTAssertEqual(SpanID.random().description.count, 16)
    }
}
