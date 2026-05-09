import XCTest
@testable import ManifoldInference

/// Tests verifying which `PromptTemplate` values expose thinking markers
/// and that `ThinkingMarkers` computes the correct holdback value.
final class PromptTemplateThinkingMarkersTests: XCTestCase {

    // MARK: - ChatML → qwen3 markers

    func test_chatML_returnsQwen3Markers() {
        let markers = PromptTemplate.chatML.thinkingMarkers
        XCTAssertNotNil(markers,
            "ChatML template must expose ThinkingMarkers (Qwen3 / DeepSeek-R1 emit <think> tags)")
        XCTAssertEqual(markers?.open, "<think>",
            "ChatML thinking open marker must be '<think>'")
        XCTAssertEqual(markers?.close, "</think>",
            "ChatML thinking close marker must be '</think>'")

        // Sabotage check: returning nil from chatML.thinkingMarkers would disable
        // thinking parsing for Qwen3 models and this assertion would fail.
    }

    // MARK: - Non-thinking templates return nil

    func test_mistral_returnsNil() {
        XCTAssertNil(PromptTemplate.mistral.thinkingMarkers,
            "Mistral template does not emit reasoning blocks; thinkingMarkers must be nil")
    }

    func test_llama3_returnsNil() {
        XCTAssertNil(PromptTemplate.llama3.thinkingMarkers,
            "Llama 3 template does not emit reasoning blocks; thinkingMarkers must be nil")
    }

    func test_gemma4_returnsGemma4Markers() {
        let markers = PromptTemplate.gemma4.thinkingMarkers
        XCTAssertNotNil(markers,
            "Gemma 4 template must expose ThinkingMarkers for thinking fine-tunes")
        XCTAssertEqual(markers?.open, "<|turn>think\n",
            "Gemma 4 thinking open marker must be '<|turn>think\\n'")
        XCTAssertEqual(markers?.close, "<|end_of_turn>",
            "Gemma 4 thinking close marker must be '<|end_of_turn>'")

        // Sabotage check: returning nil would disable thinking parsing for Gemma 4
        // thinking-enabled models and this XCTAssertNotNil would fail.
    }

    // MARK: - ThinkingMarkers.qwen3 holdback

    func test_qwen3Holdback_is8() {
        // max("<think>".count=7, "</think>".count=8) = 8
        // (The holdback is max of open and close tag lengths.)
        XCTAssertEqual(ThinkingMarkers.qwen3.holdback, 8,
            "qwen3 holdback must equal max(len('<think>'), len('</think>')) = 8")

        // Sabotage check: changing holdback to 0 would cause partial tag bytes to
        // be flushed immediately, corrupting outputs near chunk boundaries.
    }

    // MARK: - Custom markers holdback

    func test_customMarkers_holdbackEqualsMaxTagLength() {
        let markers = ThinkingMarkers.custom(open: "<<", close: ">>")
        XCTAssertEqual(markers.holdback, 2,
            "Custom markers holdback must equal max(open.count, close.count) = max(2,2) = 2")
        XCTAssertEqual(markers.open, "<<")
        XCTAssertEqual(markers.close, ">>")

        // Sabotage check: hardcoding holdback=7 (qwen3 value) would fail for
        // custom markers with shorter tags, causing this assertion to fail.
    }

    func test_customMarkers_asymmetricTags_holdbackEqualsLonger() {
        let markers = ThinkingMarkers.custom(open: "[THINK]", close: "[/T]")
        // max(7, 4) = 7
        XCTAssertEqual(markers.holdback, 7,
            "Holdback must equal the longer of open/close tags to safely buffer either partial")
    }
}
