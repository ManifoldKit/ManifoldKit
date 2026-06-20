import Foundation
import ManifoldInference

/// Pure, view-free logic for detecting inline `[n]` citation markers in assistant
/// answer text and mapping each marker to its numbered ``Citation`` source card.
///
/// The model is instructed (Piece 2 / RAG prompt, gated on #1937) to cite sources
/// inline as `[1]`, `[2]`, … where `n` is the 1-based index of the matching source
/// card already rendered by ``CitationsView``. This type does the post-stream parse:
/// it splits the answer into an ordered list of ``Segment`` values so the View can
/// render plain prose as text and each in-range marker as a tappable superscript.
///
/// Kept deliberately free of SwiftUI so the numbering / range-resolution rules are
/// unit-testable in isolation — the View layer only chooses how to *draw* the
/// segments, never *what* they are.
public enum InlineCitationRenderer {

    /// One run of the parsed answer: either a span of literal prose, or a resolved
    /// inline citation marker pointing at a source card.
    public enum Segment: Equatable, Sendable {
        /// Literal answer text to render verbatim (markdown-bearing). Includes any
        /// `[n]` token that did NOT resolve to a real citation (out-of-range,
        /// zero/negative, or no citations supplied) — such tokens stay plain so a
        /// hallucinated or mis-numbered marker never renders as a dead link.
        case text(String)

        /// A resolved marker. `displayNumber` is the 1-based number shown to the
        /// user (matching the source card's `[index]`); `citationIndex` is the
        /// 0-based offset into the `citations` array the View deep-links to.
        case marker(displayNumber: Int, citationIndex: Int)
    }

    /// Scans `text` for `[n]` markers and resolves each against `citations`.
    ///
    /// Resolution rules (why these and not "link every bracket"):
    /// - Only `[n]` where `1 <= n <= citations.count` becomes a ``Segment/marker``;
    ///   the model can hallucinate or over-count, so an out-of-range bracket must
    ///   degrade to plain text rather than crash or link nowhere.
    /// - `[0]`, negative, and non-numeric brackets (`[Link]`, `[a]`) are left as
    ///   literal text — only purely-numeric, in-range tokens are treated as
    ///   citation anchors. This intentionally leaves markdown link syntax
    ///   (`[label](url)`) untouched because `[label]` is non-numeric.
    /// - Adjacent literal runs are coalesced so the View renders the minimum number
    ///   of `Text` segments.
    ///
    /// When `citations` is empty, the result is a single ``Segment/text`` holding
    /// the original string unchanged.
    public static func segments(for text: String, citations: [Citation]) -> [Segment] {
        guard !citations.isEmpty, !text.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }

        var segments: [Segment] = []
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                segments.append(.text(literal))
                literal.removeAll(keepingCapacity: true)
            }
        }

        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            let char = scalars[i]
            if char == "[" {
                // Try to consume a `[<digits>]` token starting here.
                var j = i + 1
                var digits = ""
                while j < scalars.count, scalars[j].isNumber {
                    digits.append(scalars[j])
                    j += 1
                }
                if !digits.isEmpty, j < scalars.count, scalars[j] == "]",
                   let number = Int(digits), number >= 1, number <= citations.count {
                    // Resolved marker: flush prose, emit the marker, skip the token.
                    flushLiteral()
                    segments.append(.marker(displayNumber: number, citationIndex: number - 1))
                    i = j + 1
                    continue
                }
            }
            // Not a resolvable marker — keep the character as literal text.
            literal.append(char)
            i += 1
        }
        flushLiteral()
        return segments
    }

    /// Convenience: does `text` contain at least one *resolvable* inline marker for
    /// the supplied `citations`? Lets the View cheaply decide whether to take the
    /// segment-rendering path at all versus rendering plain markdown.
    public static func hasResolvableMarker(in text: String, citations: [Citation]) -> Bool {
        segments(for: text, citations: citations).contains {
            if case .marker = $0 { return true }
            return false
        }
    }

    /// URL scheme used to encode a citation deep-link inside the rendered
    /// `AttributedString`. The View intercepts taps on `citation://<index>` via
    /// the SwiftUI `openURL` environment action rather than navigating a browser.
    public static let deepLinkScheme = "citation"

    /// Builds the citation deep-link URL for the 0-based `citationIndex`, e.g.
    /// `citation://2`. Exposed (and pure) so the View's `openURL` handler and the
    /// renderer agree on the encoding, and so tests can assert the round-trip.
    public static func deepLinkURL(citationIndex: Int) -> URL? {
        URL(string: "\(deepLinkScheme)://\(citationIndex)")
    }

    /// Parses a citation deep-link URL back into its 0-based citation index, or
    /// `nil` when `url` is not a `citation://<index>` link. Inverse of
    /// ``deepLinkURL(citationIndex:)``.
    public static func citationIndex(from url: URL) -> Int? {
        guard url.scheme == deepLinkScheme, let host = url.host(), let index = Int(host) else {
            return nil
        }
        return index
    }
}
