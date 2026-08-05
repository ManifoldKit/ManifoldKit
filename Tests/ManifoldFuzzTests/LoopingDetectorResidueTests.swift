import XCTest
@testable import ManifoldFuzz

/// Direct coverage of `LoopingDetector.residueAfterRemovingInputEchoes`.
///
/// These exist because `inspect`-level tests structurally cannot pin this
/// logic: they observe only the guard's boolean verdict, so a range-merge
/// that removes too much OR too little is absorbed in both directions (too
/// much -> residue less loop-shaped -> echo tests still pass; too little ->
/// passes unless the leftover residue happens to look loop-shaped). Only
/// asserting the residue STRING catches an off-by-one in the projection ->
/// original index mapping or the left-extension.
final class LoopingDetectorResidueTests: XCTestCase {

    /// 20 chars, contains none of the `<>|_` characters the echo-matching
    /// projection drops, so it survives normalization unchanged.
    private let span = "ABCDEFGHIJKLMNOPQRST"

    private func residue(_ text: String, _ input: String) -> String {
        LoopingDetector.residueAfterRemovingInputEchoes(from: text, inputText: input)
    }

    func test_matchAtIndexZero_removesLeadingSpanOnly() {
        XCTAssertEqual(residue(span + "xyz", span), "xyz")
    }

    func test_matchRunningToEndOfString_removesTrailingSpan() {
        XCTAssertEqual(residue("xyz" + span, span), "xyz")
    }

    func test_backToBackMatches_bothRemoved() {
        XCTAssertEqual(residue(span + span, span), "")
    }

    /// The left-extension exists so a delimiter's dropped opener doesn't
    /// survive as its own residue. Two matches separated by nothing but
    /// dropped punctuation is the shape that produced overlapping removal
    /// ranges and crashed `removeSubrange` before the merge pass was added.
    func test_matchesSeparatedOnlyByDroppedPunctuation_leaveNoResidue() {
        XCTAssertEqual(residue(span + "<|" + span, span), "")
    }

    func test_interiorMatch_preservesBothSides() {
        XCTAssertEqual(residue("head" + span + "tail", span), "headtail")
    }

    /// Below `minSpan` nothing is removed, which is what keeps a short
    /// repeated token ("cats cats cats") firing as a genuine loop.
    func test_spanShorterThanMinSpan_isNotRemoved() {
        XCTAssertEqual(residue("head" + "SHORT" + "tail", "SHORT"), "headSHORTtail")
    }

    /// Pins the cap: a span present ONLY beyond `echoMatchInputCap` is not
    /// matched, so the text comes back untouched. Without the cap this text
    /// would be reduced to "head"/"tail".
    func test_inputBeyondCap_isNotMatched() {
        let filler = String(repeating: "z", count: LoopingDetector.echoMatchInputCap)
        XCTAssertEqual(residue("head" + span + "tail", filler + span), "head" + span + "tail")
    }

    /// Same span placed INSIDE the cap is matched — proves the previous test
    /// fails for the cap, not because the span is unmatchable.
    func test_inputWithinCap_isMatched() {
        XCTAssertEqual(residue("head" + span + "tail", span + String(repeating: "z", count: 100)), "headtail")
    }
}
