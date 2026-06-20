import SwiftUI
import ManifoldInference

/// Renders assistant prose with inline `[n]` citation markers drawn as tappable
/// superscripts that deep-link into the numbered source cards below.
///
/// Used only when the answer actually contains a *resolvable* marker (see
/// ``InlineCitationRenderer/hasResolvableMarker(in:citations:)``); plain answers
/// keep flowing through ``AssistantMarkdownView`` so we never regress markdown /
/// fenced-code rendering for the common (no-citation) case.
///
/// The whole answer is composed into one `AttributedString` so text wrapping is
/// native: prose runs are parsed as markdown (reusing the shared cache) and each
/// marker run carries a `citation://<index>` link + superscript styling. Taps are
/// intercepted by the bubble's `openURL` handler rather than opening a browser.
struct InlineCitationTextView: View {
    let content: String
    let citations: [Citation]

    var body: some View {
        Text(Self.attributedString(content: content, citations: citations))
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            // why: tint the marker links so they read as the same accent the
            // source-card `[n]` uses, and stay visually distinct from prose.
            .tint(.accentColor)
    }

    /// Composes the answer into a single markdown-aware `AttributedString` with
    /// each resolved marker rendered as a tappable, superscript `[n]` link.
    ///
    /// Pure and `static` so it can be exercised without standing up a SwiftUI host.
    static func attributedString(content: String, citations: [Citation]) -> AttributedString {
        var result = AttributedString()
        for segment in InlineCitationRenderer.segments(for: content, citations: citations) {
            switch segment {
            case .text(let prose):
                // Reuse the cached markdown renderer so prose styling matches the
                // non-citation path exactly.
                result.append(AssistantMarkdownParser.attributedString(from: prose))
            case .marker(let displayNumber, let citationIndex):
                var marker = AttributedString("[\(displayNumber)]")
                if let url = InlineCitationRenderer.deepLinkURL(citationIndex: citationIndex) {
                    marker.link = url
                }
                // Superscript baseline + smaller weight reads as a citation anchor
                // without stealing prose line height.
                marker.baselineOffset = 4
                marker.font = .caption2.weight(.semibold)
                marker.foregroundColor = .accentColor
                result.append(marker)
            }
        }
        return result
    }
}

#Preview("Inline markers") {
    let docID = UUID()
    return InlineCitationTextView(
        content: "Retrieval-augmented generation grounds answers in sources [1], reducing hallucination [2].",
        citations: [
            Citation(documentID: docID, documentTitle: "rag.md", chunkIndex: 0, snippet: "RAG grounds answers.", score: 0.9),
            Citation(documentID: docID, documentTitle: "eval.md", chunkIndex: 1, snippet: "Grounding cuts hallucination.", score: 0.8),
        ]
    )
    .padding()
}
