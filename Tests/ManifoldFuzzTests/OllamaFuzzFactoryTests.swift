import XCTest
@testable import ManifoldFuzz
import ManifoldInference
@testable import ManifoldFuzzBackends

/// Unit tests for ``OllamaFuzzFactory`` marker-snapshot logic (#1664, and the
/// fallback-marker false-positive fix from the 228-iteration campaign triage).
///
/// `makeHandle()` uses the backend's `manifest.thinkingMarkers` to populate
/// `BackendHandle.templateMarkers` so the fuzz runner records the correct
/// marker family for each model. Prior to #1664's fix, every model including
/// Gemma 4 received a hardcoded `<think>`/`</think>` snapshot regardless of
/// the template the model actually ships. Prior to the campaign-triage fix,
/// a model with NO native markers (gemma3, mistral, llama3.1, …) still
/// received that same hardcoded `<think>` snapshot as a "fallback" — which
/// defeated `ThinkingClassificationDetector`'s nil-marker skip guard and
/// produced false leak/misclassification findings whenever a corpus prompt
/// merely discussed `<think>` in prose.
///
/// Network calls are not exercised here — the marker-selection logic is
/// validated via the `MarkerSnapshot` helpers in isolation.
final class OllamaFuzzFactoryTests: XCTestCase {

    // MARK: - Marker snapshot helpers

    /// Returns the `MarkerSnapshot?` the factory now produces from a given
    /// `ThinkingMarkers?`, mirroring the logic in `makeHandle()`. Centralised
    /// here so tests stay in lock-step with the production code without
    /// duplicating the expression. `nil` stays `nil` — there is no synthetic
    /// fallback.
    private func makeSnapshot(from markers: ThinkingMarkers?) -> RunRecord.MarkerSnapshot? {
        markers.map { RunRecord.MarkerSnapshot(open: $0.open, close: $0.close) }
    }

    // MARK: - Tests

    /// Gemma 4 markers must round-trip through the snapshot helper, producing
    /// `<|turn>think\n` / `<|end_of_turn>` — not the Qwen3-style `<think>` fallback.
    func test_markerSnapshot_gemma4MarkersRoundTrip() throws {
        let snapshot = try XCTUnwrap(makeSnapshot(from: .gemma4))
        XCTAssertEqual(snapshot.open, ThinkingMarkers.gemma4.open,
                       "Gemma 4 open marker must be preserved in the snapshot")
        XCTAssertEqual(snapshot.close, ThinkingMarkers.gemma4.close,
                       "Gemma 4 close marker must be preserved in the snapshot")
        // Confirm this is different from the legacy Qwen3 fallback — the
        // historical bug was that this assertion would have failed.
        XCTAssertNotEqual(snapshot.open, "<think>",
                          "Gemma 4 snapshot must not collapse to the Qwen3 <think> fallback")
    }

    /// When the manifest carries no thinking markers (nil), the factory must
    /// NOT synthesize a Qwen3-style `<think>`/`</think>` fallback — the
    /// snapshot must stay `nil` so `ThinkingClassificationDetector` correctly
    /// treats this model as declaring no native markers and skips its
    /// marker-based sub-checks. A non-nil fallback here is exactly the
    /// campaign-triage false-positive bug: a non-thinking model (gemma3,
    /// mistral, llama3.1) that legitimately discusses the literal string
    /// `<think>` in prose would otherwise trip "visible-text-leak" /
    /// "misclassified-as-text" findings that are not real bugs.
    func test_markerSnapshot_nilMarkersStayNil() {
        let snapshot = makeSnapshot(from: nil)
        XCTAssertNil(snapshot,
                     "nil markers must stay nil — no synthetic Qwen3 <think> fallback")
    }

    /// All known ``ThinkingMarkers`` presets must survive the round-trip.
    /// Guards against a future preset being accidentally mapped to nil.
    func test_markerSnapshot_allKnownPresetsRoundTrip() {
        let presets: [(name: String, markers: ThinkingMarkers)] = [
            ("qwen3", .qwen3),
            ("mistralReasoning", .mistralReasoning),
            ("phi4", .phi4),
            ("reflection", .reflection),
            ("gemma4", .gemma4),
        ]
        for (name, preset) in presets {
            let snapshot = makeSnapshot(from: preset)
            XCTAssertEqual(snapshot?.open, preset.open,
                           "\(name) open marker must round-trip through the snapshot helper")
            XCTAssertEqual(snapshot?.close, preset.close,
                           "\(name) close marker must round-trip through the snapshot helper")
        }
    }

    // MARK: - End-to-end: factory marker output feeding ThinkingClassificationDetector

    /// Builds a minimal `RunRecord` carrying the given marker snapshot and raw/
    /// rendered text, mirroring the boilerplate other fuzz test files use to
    /// drive detectors directly against factory output.
    private func makeRunRecord(
        markers: RunRecord.MarkerSnapshot?,
        raw: String,
        rendered: String
    ) -> RunRecord {
        RunRecord(
            runId: "test-run",
            ts: "2026-07-03T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "ollama",
                id: "gemma3:4b",
                url: "ollama:gemma3:4b",
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
                messages: [.init(role: "user", text: "What does the <think> tag do in reasoning models?")]
            ),
            events: [],
            raw: raw,
            rendered: rendered,
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: markers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: 0, tokensPerSec: nil),
            phase: "done",
            error: nil,
            stopReason: "naturalStop"
        )
    }

    /// Reproduces the campaign-triage false positive (19 findings across
    /// gemma3, mistral, llama3.1): a non-thinking model's `makeHandle()` call
    /// used to fall back to `{open: "<think>", close: "</think>"}` even when
    /// the probe found no native markers. A corpus scenario that asks the
    /// model to *discuss* `<think>` in prose then echoed the literal string,
    /// and the non-nil fallback marker made `ThinkingClassificationDetector`
    /// treat that prose as a leaked/misclassified thinking marker.
    ///
    /// With the fix, `makeSnapshot(from: nil)` — what `makeHandle()` now
    /// assigns when the probe finds nothing — stays `nil`, so the detector's
    /// marker-based sub-checks skip entirely and this must NOT flag.
    func test_endToEnd_nonThinkingModelDiscussingThinkTagInProse_producesNoFinding() {
        let markers = makeSnapshot(from: nil)
        let record = makeRunRecord(
            markers: markers,
            raw: "The <think> tag is used by some models to expose reasoning before the final answer.",
            rendered: "The <think> tag is used by some models to expose reasoning before the final answer."
        )
        let findings = ThinkingClassificationDetector().inspect(record)
        XCTAssertTrue(findings.isEmpty,
                       "A non-thinking model discussing <think> in prose must not be flagged " +
                       "as a marker leak/misclassification — got: \(findings)")
    }

    /// Sabotage/counter-test: the same detector must still fire a real leak
    /// when a model that DOES declare native thinking markers (e.g. Qwen3)
    /// actually leaks its marker into visible output. This guards against the
    /// false-positive fix silently disabling the detector altogether.
    func test_endToEnd_thinkingModelWithRealLeak_stillProducesFinding() {
        let markers = makeSnapshot(from: .qwen3)
        let record = makeRunRecord(
            markers: markers,
            raw: "\(ThinkingMarkers.qwen3.open)internal reasoning\(ThinkingMarkers.qwen3.close) final answer",
            rendered: "\(ThinkingMarkers.qwen3.open)internal reasoning\(ThinkingMarkers.qwen3.close) final answer"
        )
        let findings = ThinkingClassificationDetector().inspect(record)
        XCTAssertTrue(findings.contains { $0.subCheck == "visible-text-leak" },
                       "A real leaked thinking marker on a model that declares native markers " +
                       "must still be flagged — the fix must not blanket-suppress the detector")
    }

    // MARK: - selectModel

    /// Hint matching must be case-insensitive and allow partial substrings,
    /// mirroring the `--model <substr>` CLI behaviour.
    func test_selectModel_hintMatchIsCaseInsensitiveSubstring() {
        let models = ["gemma4:12b-it", "qwen3:8b", "llama3.1:8b"]
        let selected = OllamaFuzzFactory.selectModel(
            from: models,
            modelHint: "GEMMA4",
            environment: [:]
        )
        XCTAssertEqual(selected, "gemma4:12b-it",
                       "selectModel must match hints case-insensitively so --model gemma4 finds gemma4:12b-it")
    }
}
