#if Fuzz
import XCTest
@testable import ManifoldFuzz
import ManifoldInference

final class DetectorTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeRecord(
        rendered: String = "",
        raw: String = "",
        thinkingRaw: String = "",
        thinkingParts: [String] = [],
        thinkingCompleteCount: Int = 0,
        phase: String = "done",
        totalMs: Double = 0,
        error: String? = nil,
        markers: RunRecord.MarkerSnapshot? = .init(open: "<think>", close: "</think>"),
        userPrompt: String = "what is two plus two?",
        stopReason: String? = "naturalStop"
    ) -> RunRecord {
        RunRecord(
            runId: "test-run",
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "mock",
                id: "test-model",
                url: "mem://test",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 0,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: nil,
                systemPrompt: nil
            ),
            prompt: .init(
                corpusId: "test",
                mutators: [],
                messages: [.init(role: "user", text: userPrompt)]
            ),
            events: [],
            // `rendered` is deprecated (always a duplicate of `raw` in
            // production). Mirror it when only one of the two is set so legacy
            // test call sites passing `rendered:` still drive the detectors,
            // which now read `raw`.
            raw: raw.isEmpty ? rendered : raw,
            rendered: rendered.isEmpty ? raw : rendered,
            thinkingRaw: thinkingRaw,
            thinkingParts: thinkingParts,
            thinkingCompleteCount: thinkingCompleteCount,
            templateMarkers: markers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: totalMs, tokensPerSec: nil),
            phase: phase,
            error: error,
            stopReason: stopReason
        )
    }

    // MARK: - ThinkingClassificationDetector — positive

    func test_thinkingClassification_visibleTextLeak_firesWhenOpenMarkerInRendered() {
        let r = makeRecord(rendered: "answer with <think>oops</think>")
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "visible-text-leak" })
    }

    func test_thinkingClassification_misclassifiedAsText_firesWhenRawHasMarkerButNoStructuredThinking() {
        let r = makeRecord(raw: "<think>reasoning")
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "misclassified-as-text" })
    }

    func test_thinkingClassification_orphanThinkingComplete_firesOnEmptyThinkingRawWithCompletes() {
        let r = makeRecord(thinkingRaw: "", thinkingCompleteCount: 2)
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "orphan-thinking-complete" })
    }

    func test_thinkingClassification_unbalancedEvents_firesWhenThinkingNeverClosedButPhaseDone() {
        let r = makeRecord(thinkingRaw: "thinking...", thinkingCompleteCount: 0, phase: "done")
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "unbalanced-thinking-events" })
    }

    // MARK: - ThinkingClassificationDetector — negative

    func test_thinkingClassification_cleanRecord_producesNoFindings() {
        let r = makeRecord(rendered: "Hello, world.", raw: "Hello, world.")
        XCTAssertTrue(ThinkingClassificationDetector().inspect(r).isEmpty)
    }

    func test_thinkingClassification_properThinkingEvents_producesNoFindings() {
        // Backends that surface thinking via structured events strip markers
        // out of `raw` itself — post-#499, detectors read `raw` directly, so
        // keeping markers out of `raw` is the correct negative shape.
        let r = makeRecord(
            raw: "final answer",
            thinkingRaw: "reason",
            thinkingParts: ["reason"],
            thinkingCompleteCount: 1
        )
        XCTAssertTrue(ThinkingClassificationDetector().inspect(r).isEmpty)
    }

    func test_thinkingClassification_customMarkersDoNotFireOnDefaultThinkTag() {
        // Template uses <reasoning>...</reasoning>; a literal `<think>` in rendered/raw
        // should not be treated as a marker leak because the configured open marker is
        // `<reasoning>`. Without templateMarkers honour, this would trip visible-text-leak.
        let r = makeRecord(
            rendered: "answer with <think>not-a-marker-here</think>",
            raw: "answer with <think>not-a-marker-here</think>",
            markers: .init(open: "<reasoning>", close: "</reasoning>")
        )
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "visible-text-leak" })
        XCTAssertFalse(findings.contains { $0.subCheck == "misclassified-as-text" })
    }

    func test_thinkingClassification_noMarkersBackend_suppressesVisibleTextLeak() {
        // FoundationBackend and LlamaBackend have templateMarkers = nil.
        // A prompt that discusses <think> tags (e.g. "Use the <think> tag in output")
        // should not trigger visible-text-leak because these backends never emit
        // native thinking blocks — the marker text is literal user content.
        let r = makeRecord(
            raw: "Use the <think> tag in output",
            markers: nil
        )
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "visible-text-leak" })
    }

    func test_thinkingClassification_noMarkersBackend_suppressesMisclassifiedAsText() {
        // Same nil-markers scenario: raw contains the open marker string but there are
        // no structured thinking events. For a backend that never declared markers this
        // is not a misclassification — the text is intentional user-visible content.
        let r = makeRecord(
            raw: "<think>reasoning content",
            thinkingRaw: "",
            markers: nil
        )
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "misclassified-as-text" })
    }

    // MARK: - LoopingDetector — positive

    func test_looping_renderedLoop_firesOnRepetitiveRendered() {
        let looped = String(repeating: "hello world. ", count: 30)
        XCTAssertTrue(RepetitionDetector.looksLikeLooping(looped), "fixture must actually look like looping")
        XCTAssertGreaterThanOrEqual(looped.count, 100)
        let r = makeRecord(rendered: looped)
        let findings = LoopingDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "rendered-loop" })
    }

    func test_looping_thinkingLoop_firesOnRepetitiveThinkingAndDoesNotFireRendered() {
        let looped = String(repeating: "thinking step. ", count: 30)
        XCTAssertTrue(RepetitionDetector.looksLikeLooping(looped))
        let r = makeRecord(rendered: "", thinkingRaw: looped)
        let findings = LoopingDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "thinking-loop" })
        XCTAssertFalse(findings.contains { $0.subCheck == "rendered-loop" })
    }

    // MARK: - LoopingDetector — negative

    func test_looping_shortRendered_doesNotFire() {
        // Below the 100-char floor, even obvious repetition is ignored.
        let short = String(repeating: "ab", count: 20) // 40 chars
        let r = makeRecord(rendered: short)
        XCTAssertTrue(LoopingDetector().inspect(r).isEmpty)
    }

    func test_looping_variedProse_doesNotFire() {
        let prose = """
        The quick brown fox jumps over the lazy dog while a curious cat watches \
        from the windowsill. Outside, rain begins to tap against the glass and \
        a distant train whistles through the valley. Inside, the kettle clicks \
        off and steam curls toward the ceiling beams.
        """
        XCTAssertFalse(RepetitionDetector.looksLikeLooping(prose), "fixture must not be loop-shaped")
        let r = makeRecord(rendered: prose, thinkingRaw: prose)
        XCTAssertTrue(LoopingDetector().inspect(r).isEmpty)
    }

    // MARK: - EmptyOutputAfterWorkDetector

    func test_emptyOutputAfterWork_firesWhenSlowAndSilent() {
        let r = makeRecord(rendered: "", raw: "", thinkingRaw: "", phase: "done", totalMs: 9_000, error: nil)
        let findings = EmptyOutputAfterWorkDetector().inspect(r)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.subCheck, "silent-empty")
    }

    func test_emptyOutputAfterWork_triggerIsStableAcrossRuns() {
        // Same logical bug at slightly different wall-clock totals must dedup
        // to one finding (trigger drops totalMs in favour of categorical buckets).
        let a = makeRecord(rendered: "", raw: "", thinkingRaw: "", phase: "done", totalMs: 9_001)
        let b = makeRecord(rendered: "", raw: "", thinkingRaw: "", phase: "done", totalMs: 11_234)
        let triggerA = EmptyOutputAfterWorkDetector().inspect(a).first?.trigger
        let triggerB = EmptyOutputAfterWorkDetector().inspect(b).first?.trigger
        XCTAssertNotNil(triggerA)
        XCTAssertEqual(triggerA, triggerB)
    }

    func test_emptyOutputAfterWork_doesNotFireWhenFast() {
        let r = makeRecord(rendered: "", raw: "", thinkingRaw: "", phase: "done", totalMs: 100)
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(r).isEmpty)
    }

    func test_emptyOutputAfterWork_doesNotFireBelowDefault8sThreshold() {
        // Cold-start guard: 5s used to fire under the old 3s threshold.
        let r = makeRecord(rendered: "", raw: "", thinkingRaw: "", phase: "done", totalMs: 5_000)
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(r).isEmpty)
    }

    func test_emptyOutputAfterWork_doesNotFireOnEmptyPromptSeed() {
        // Corpus seeds `empty-prompt` and `whitespace-only` produce empty output by design.
        let empty = makeRecord(rendered: "", thinkingRaw: "", phase: "done", totalMs: 10_000, userPrompt: "")
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(empty).isEmpty)
        let ws = makeRecord(rendered: "", thinkingRaw: "", phase: "done", totalMs: 10_000, userPrompt: "   \n\t   ")
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(ws).isEmpty)
    }

    func test_emptyOutputAfterWork_doesNotFireWhenContentPresent() {
        let r = makeRecord(rendered: "answer", thinkingRaw: "", phase: "done", totalMs: 10_000)
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(r).isEmpty)
    }

    func test_emptyOutputAfterWork_doesNotFireWhenThinkingPresent() {
        let r = makeRecord(rendered: "", thinkingRaw: "reasoning was captured", phase: "done", totalMs: 10_000)
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(r).isEmpty)
    }

    func test_emptyOutputAfterWork_doesNotFireOnError() {
        let r = makeRecord(rendered: "", thinkingRaw: "", phase: "failed", totalMs: 10_000, error: "boom", stopReason: "error")
        XCTAssertTrue(EmptyOutputAfterWorkDetector().inspect(r).isEmpty)
    }

    // MARK: - TemplateTokenLeakDetector — negative (token already in input)

    func test_templateTokenLeak_inputContainsToken_suppressesFinding() {
        // Foundation has no template engine; it echoes ChatML tokens verbatim
        // when they appear in the user's prompt. This must NOT fire.
        let r = makeRecord(
            raw: "The <|im_start|> delimiter is used in ChatML.",
            userPrompt: "Explain the <|im_start|> ChatML delimiter"
        )
        let findings = TemplateTokenLeakDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "template-fragment" })
    }

    func test_templateTokenLeak_mutatorInjected_suppressesFinding() {
        // TemplateTokenInjectMutator injects tokens into the user prompt;
        // echoing them back is expected, not a bug.
        let r = makeRecord(
            raw: "The capital of<|im_start|> France is Paris.",
            userPrompt: "What is<|im_start|>the capital of France?"
        )
        let findings = TemplateTokenLeakDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "template-fragment" })
    }

    // MARK: - TemplateTokenLeakDetector — positive (spontaneous generation)

    func test_templateTokenLeak_spontaneousToken_firesWhenNotInInput() {
        // The user's prompt contains no template tokens; if one appears in the
        // raw output the backend has a genuine template-leak bug.
        let r = makeRecord(
            raw: "The capital is <|im_start|>Paris.",
            userPrompt: "What is the capital of France?"
        )
        let findings = TemplateTokenLeakDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "template-fragment" })
    }

    // MARK: - ThinkingClassificationDetector — stopReason gating

    func test_thinkingClassification_unbalancedEvents_skipsWhenMaxTokensTruncation() {
        // 64-token cap routinely truncates mid-`<think>` on reasoning models;
        // the lack of a `thinkingComplete` event is the cap's fault, not a parser bug.
        let r = makeRecord(
            thinkingRaw: "still reasoning…",
            thinkingCompleteCount: 0,
            phase: "done",
            stopReason: "maxTokens"
        )
        let findings = ThinkingClassificationDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "unbalanced-thinking-events" })
    }
}
#endif
