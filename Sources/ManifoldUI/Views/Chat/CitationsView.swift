import SwiftUI
import ManifoldInference

/// Renders the "Sources" disclosure shown beneath a RAG-augmented assistant
/// message bubble.
///
/// Collapsed by default — the disclosure label shows the source count and
/// expands into a vertical stack of per-citation rows. Each row prints the
/// document title, chunk index, score, and a truncated snippet of the
/// retrieved passage. Designed to mirror the existing
/// ``ThinkingBlockView`` idiom (collapsed-by-default `DisclosureGroup` with
/// caption typography) so adopters get a familiar feel without learning a
/// new control.
public struct CitationsView: View {

    public let citations: [Citation]
    @State private var isExpanded: Bool = false

    public init(citations: [Citation]) {
        self.citations = citations
    }

    public var body: some View {
        if citations.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                        CitationRow(index: index + 1, citation: citation)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption)
                    Text("\(citations.count) source\(citations.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("assistant-citations-disclosure")
        }
    }
}

// MARK: - CitationRow

private struct CitationRow: View {
    let index: Int
    let citation: Citation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("[\(index)]")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.tint)
                Text(citation.documentTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("· chunk \(citation.chunkIndex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if citation.score > 0 {
                    Text(scoreLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Relevance score \(scoreLabel)")
                }
            }
            Text(citation.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(index): \(citation.documentTitle), chunk \(citation.chunkIndex). \(citation.snippet)")
    }

    private var scoreLabel: String {
        String(format: "%.2f", citation.score)
    }
}

// MARK: - Preview

#Preview("Three sources") {
    CitationsView(citations: [
        Citation(
            documentID: UUID(),
            documentTitle: "Whitepaper.pdf",
            chunkIndex: 2,
            snippet: "The retrieval-augmented generation pattern combines a vector search index with an autoregressive language model so that answers can cite specific sources rather than relying solely on parameterized memory.",
            score: 0.91
        ),
        Citation(
            documentID: UUID(),
            documentTitle: "design-notes.txt",
            chunkIndex: 0,
            snippet: "FlatFileVectorStore is correct up to ~50k chunks; sqlite-vec ANN comes in Phase 3.",
            score: 0.78
        ),
        Citation(
            documentID: UUID(),
            documentTitle: "release-notes.md",
            chunkIndex: 4,
            snippet: "Phase 2 adds the document library UI, source citations, and demo wiring.",
            score: 0.66
        ),
    ])
    .padding()
}

#Preview("Empty (renders nothing)") {
    CitationsView(citations: [])
        .padding()
}
