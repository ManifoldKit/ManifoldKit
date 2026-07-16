import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Regression coverage for the head-preservation fix in `EventRecorder`'s
/// truncation strategy (see #2266's fuzz-harness-timeout-hardening PR
/// review). Pure front-drop truncation preserves the TAIL of `raw`/
/// `thinkingRaw` — which is exactly what `LoopingDetector` needs — but it
/// blinds any detector that scans for a marker appearing near the START of a
/// response: `ThinkingClassificationDetector`'s "misclassified-as-text"
/// sub-check and `TemplateTokenLeakDetector` both look for a leaked marker
/// that a real backend emits in its first few tokens. These tests drive a
/// genuinely-oversized generation through the real `EventRecorder.consume`
/// pipeline (not a hand-built record) and confirm both detectors still fire
/// once `truncated == true`.
final class TruncationDetectorRegressionTests: XCTestCase {

    private func loadedBackend(tokensToYield: [String]) async throws -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.tokensToYield = tokensToYield
        try await backend.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())
        return backend
    }

    /// Minimal `RunRecord` mirroring `FuzzRunner.runSingle`'s construction,
    /// scoped to only the fields these two detectors read.
    private func makeRecord(
        capture: EventRecorder.Capture,
        promptText: String,
        templateMarkers: RunRecord.MarkerSnapshot?
    ) -> RunRecord {
        RunRecord(
            runId: UUID().uuidString,
            ts: "2026-01-01T00:00:00Z",
            harness: .init(
                fuzzVersion: "test",
                packageGitRev: "test",
                packageGitDirty: false,
                swiftVersion: "test",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(backend: "mock", id: "mock-model", url: "mock:mock-model"),
            config: .init(seed: 1, temperature: 0, topP: 1, maxTokens: nil, systemPrompt: nil),
            prompt: .init(corpusId: "regression", mutators: [], messages: [.init(role: "user", text: promptText)]),
            events: capture.events,
            raw: capture.raw,
            rendered: capture.raw,
            thinkingRaw: capture.thinkingRaw,
            thinkingParts: capture.thinkingParts,
            thinkingCompleteCount: capture.thinkingCompleteCount,
            templateMarkers: templateMarkers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: capture.firstTokenMs, totalMs: capture.totalMs, tokensPerSec: nil),
            phase: capture.phase,
            error: capture.error,
            stopReason: capture.stopReason,
            truncated: capture.truncated
        )
    }

    /// A `<think>` open marker emitted as the very first token, followed by
    /// enough filler to blow past `maxBufferedCharacters`, still trips
    /// `ThinkingClassificationDetector`'s "misclassified-as-text" sub-check
    /// (marker leaked into `raw`/text instead of the thinking channel) even
    /// though the record was truncated.
    func test_thinkingClassificationDetector_stillFiresOnTruncatedRecord() async throws {
        let filler = String(repeating: "A", count: EventRecorder.maxBufferedCharacters + 1_000_000)
        let backend = try await loadedBackend(tokensToYield: ["<think>", filler])
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated, "the filler token alone must exceed the cap for this test to be meaningful")

        let record = makeRecord(
            capture: capture,
            promptText: "hi",
            templateMarkers: RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        )
        let findings = ThinkingClassificationDetector().inspect(record)

        XCTAssertTrue(
            findings.contains { $0.subCheck == "misclassified-as-text" },
            "the leaked <think> marker sits in the preserved HEAD segment and must still be visible to the detector after truncation"
        )
    }

    /// A ChatML template token leaked as the first token, followed by enough
    /// filler to exceed the cap, still trips `TemplateTokenLeakDetector`
    /// after truncation.
    func test_templateTokenLeakDetector_stillFiresOnTruncatedRecord() async throws {
        let filler = String(repeating: "A", count: EventRecorder.maxBufferedCharacters + 1_000_000)
        let backend = try await loadedBackend(tokensToYield: ["<|im_start|>", filler])
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated, "the filler token alone must exceed the cap for this test to be meaningful")

        // Prompt text deliberately does NOT contain the fragment, so the
        // detector's echo-guard doesn't suppress the finding.
        let record = makeRecord(capture: capture, promptText: "hi", templateMarkers: nil)
        let findings = TemplateTokenLeakDetector().inspect(record)

        XCTAssertTrue(
            findings.contains { $0.trigger == "<|im_start|>" },
            "the leaked template token sits in the preserved HEAD segment and must still be visible to the detector after truncation"
        )
    }

    /// Both ends survive simultaneously: a marker at the head AND a
    /// repeating pattern at the tail are both detectable from the same
    /// truncated record — proof the head/tail split doesn't just trade one
    /// blind spot for the other.
    func test_headMarkerAndTailLoop_bothSurviveTruncation() async throws {
        let loop = String(repeating: "loop-forever ", count: 200_000) // well past maxBufferedCharacters
        let backend = try await loadedBackend(tokensToYield: ["<think>", loop])
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated)
        XCTAssertTrue(capture.raw.hasPrefix("<think>"))
        XCTAssertTrue(capture.raw.hasSuffix("loop-forever "))
    }
}
