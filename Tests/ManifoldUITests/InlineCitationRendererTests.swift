@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldInference

/// Unit tests for the pure inline-citation marker logic
/// (``InlineCitationRenderer``). The View layer only chooses how to *draw* the
/// segments, so all the numbering / range-resolution rules are asserted here
/// without a SwiftUI host.
final class InlineCitationRendererTests: XCTestCase {

    // MARK: - Fixtures

    private func citation(_ title: String, chunk: Int = 0) -> Citation {
        Citation(
            documentID: UUID(),
            documentTitle: title,
            chunkIndex: chunk,
            snippet: "snippet for \(title)",
            score: 0.5
        )
    }

    private var twoCitations: [Citation] {
        [citation("a.md"), citation("b.md")]
    }

    // MARK: - Marker mapping

    func test_segments_mapsMarkersToCitationIndices() {
        let segments = InlineCitationRenderer.segments(
            for: "Foo [1] bar [2].",
            citations: twoCitations
        )

        XCTAssertEqual(segments, [
            .text("Foo "),
            .marker(displayNumber: 1, citationIndex: 0),
            .text(" bar "),
            .marker(displayNumber: 2, citationIndex: 1),
            .text("."),
        ])

        // Sabotage: with zero citations, the same text must stay entirely plain —
        // confirms linking is citation-driven, not just "any [n] becomes a marker".
        let noCitations = InlineCitationRenderer.segments(for: "Foo [1] bar [2].", citations: [])
        XCTAssertEqual(noCitations, [.text("Foo [1] bar [2].")])
    }

    func test_segments_displayNumberIsOneBased_indexIsZeroBased() {
        let segments = InlineCitationRenderer.segments(for: "[2]", citations: twoCitations)
        XCTAssertEqual(segments, [.marker(displayNumber: 2, citationIndex: 1)])
    }

    // MARK: - Out-of-range / malformed markers degrade to plain text

    func test_segments_outOfRangeMarkerLeftPlain() {
        // [3] with only 2 citations — must NOT link and must NOT crash.
        let segments = InlineCitationRenderer.segments(for: "x [3] y", citations: twoCitations)
        XCTAssertEqual(segments, [.text("x [3] y")])
        XCTAssertFalse(segments.contains { if case .marker = $0 { return true }; return false })
    }

    func test_segments_zeroAndNegativeMarkersLeftPlain() {
        XCTAssertEqual(
            InlineCitationRenderer.segments(for: "a [0] b", citations: twoCitations),
            [.text("a [0] b")]
        )
        // "[-1]" — the leading '-' isn't a digit so it is never read as a marker.
        XCTAssertEqual(
            InlineCitationRenderer.segments(for: "a [-1] b", citations: twoCitations),
            [.text("a [-1] b")]
        )
    }

    func test_segments_nonNumericBracketsLeftPlain_includingMarkdownLinks() {
        // Markdown link syntax must survive untouched: `[Docs]` is non-numeric.
        let input = "See [Docs](https://example.com) and [note]."
        let segments = InlineCitationRenderer.segments(for: input, citations: twoCitations)
        XCTAssertEqual(segments, [.text(input)])
    }

    func test_segments_unterminatedBracketLeftPlain() {
        XCTAssertEqual(
            InlineCitationRenderer.segments(for: "open [1 no close", citations: twoCitations),
            [.text("open [1 no close")]
        )
    }

    // MARK: - Coalescing / edge inputs

    func test_segments_adjacentMarkersCoalesceSurroundingProse() {
        let segments = InlineCitationRenderer.segments(for: "[1][2]", citations: twoCitations)
        XCTAssertEqual(segments, [
            .marker(displayNumber: 1, citationIndex: 0),
            .marker(displayNumber: 2, citationIndex: 1),
        ])
    }

    func test_segments_emptyTextReturnsEmpty() {
        XCTAssertEqual(InlineCitationRenderer.segments(for: "", citations: twoCitations), [])
    }

    func test_segments_repeatedMarkerResolvesEachTime() {
        let segments = InlineCitationRenderer.segments(for: "[1] and again [1]", citations: twoCitations)
        XCTAssertEqual(segments, [
            .marker(displayNumber: 1, citationIndex: 0),
            .text(" and again "),
            .marker(displayNumber: 1, citationIndex: 0),
        ])
    }

    // MARK: - hasResolvableMarker

    func test_hasResolvableMarker_trueOnlyWhenInRangeMarkerPresent() {
        XCTAssertTrue(InlineCitationRenderer.hasResolvableMarker(in: "x [1]", citations: twoCitations))
        XCTAssertFalse(InlineCitationRenderer.hasResolvableMarker(in: "x [3]", citations: twoCitations))
        XCTAssertFalse(InlineCitationRenderer.hasResolvableMarker(in: "x [1]", citations: []))
        XCTAssertFalse(InlineCitationRenderer.hasResolvableMarker(in: "plain text", citations: twoCitations))
    }

    // MARK: - Deep-link URL round-trip

    func test_deepLinkURL_roundTripsCitationIndex() {
        guard let url = InlineCitationRenderer.deepLinkURL(citationIndex: 2) else {
            return XCTFail("expected a deep-link URL")
        }
        XCTAssertEqual(url.scheme, InlineCitationRenderer.deepLinkScheme)
        XCTAssertEqual(InlineCitationRenderer.citationIndex(from: url), 2)
    }

    func test_citationIndex_returnsNilForNonCitationURL() {
        guard let httpURL = URL(string: "https://example.com/3") else {
            return XCTFail("bad fixture URL")
        }
        XCTAssertNil(InlineCitationRenderer.citationIndex(from: httpURL))
    }

    // MARK: - AttributedString rendering (View helper, pure)

    @MainActor
    func test_attributedString_markerCarriesDeepLinkAndProseHasNoLink() {
        let attributed = InlineCitationTextView.attributedString(
            content: "Grounded answer [1].",
            citations: twoCitations
        )
        let linkedRuns = attributed.runs.filter { $0.link != nil }
        XCTAssertEqual(linkedRuns.count, 1, "exactly the one in-range marker should be a link")
        XCTAssertEqual(linkedRuns.first?.link, InlineCitationRenderer.deepLinkURL(citationIndex: 0))

        // Sabotage: drop citations and the marker must lose its link entirely.
        let unlinked = InlineCitationTextView.attributedString(
            content: "Grounded answer [1].",
            citations: []
        )
        XCTAssertTrue(unlinked.runs.allSatisfy { $0.link == nil })
    }
}
