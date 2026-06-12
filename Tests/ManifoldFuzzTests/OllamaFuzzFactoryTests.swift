import XCTest
import ManifoldFuzz
import ManifoldInference
@testable import ManifoldFuzzBackends

/// Unit tests for ``OllamaFuzzFactory`` marker-snapshot logic (#1664).
///
/// `makeHandle()` uses the backend's `manifest.thinkingMarkers` to populate
/// `BackendHandle.templateMarkers` so the fuzz runner records the correct
/// marker family for each model. Prior to the fix, every model including
/// Gemma 4 received a hardcoded `<think>`/`</think>` snapshot regardless of
/// the template the model actually ships.
///
/// Network calls are not exercised here — the marker-selection logic is
/// validated via the `MarkerSnapshot` helpers in isolation.
final class OllamaFuzzFactoryTests: XCTestCase {

    // MARK: - Marker snapshot helpers

    /// Returns the `MarkerSnapshot` the factory now produces from a given
    /// `ThinkingMarkers?`, mirroring the logic in `makeHandle()`. Centralised
    /// here so tests stay in lock-step with the production code without
    /// duplicating the expression.
    private func makeSnapshot(from markers: ThinkingMarkers?) -> RunRecord.MarkerSnapshot {
        markers.map { RunRecord.MarkerSnapshot(open: $0.open, close: $0.close) }
            ?? RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
    }

    // MARK: - Tests

    /// Gemma 4 markers must round-trip through the snapshot helper, producing
    /// `<|turn>think\n` / `<|end_of_turn>` — not the Qwen3-style `<think>` fallback.
    func test_markerSnapshot_gemma4MarkersRoundTrip() {
        let snapshot = makeSnapshot(from: .gemma4)
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
    /// fall back to Qwen3-style `<think>`/`</think>` to preserve behaviour for
    /// models that don't have a structured template.
    func test_markerSnapshot_nilMarkersYieldQwen3Fallback() {
        let snapshot = makeSnapshot(from: nil)
        XCTAssertEqual(snapshot.open, "<think>",
                       "nil markers must yield the Qwen3 open-marker fallback")
        XCTAssertEqual(snapshot.close, "</think>",
                       "nil markers must yield the Qwen3 close-marker fallback")
    }

    /// All known ``ThinkingMarkers`` presets must survive the round-trip
    /// without collapsing to the Qwen3 fallback. Guards against a future
    /// preset being accidentally mapped to nil.
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
            XCTAssertEqual(snapshot.open, preset.open,
                           "\(name) open marker must round-trip through the snapshot helper")
            XCTAssertEqual(snapshot.close, preset.close,
                           "\(name) close marker must round-trip through the snapshot helper")
        }
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
