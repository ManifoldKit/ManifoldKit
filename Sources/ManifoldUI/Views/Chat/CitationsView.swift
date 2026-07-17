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

    /// Fired when the user taps a source row. Hosts that present a richer source
    /// view (e.g. `DocumentLibraryView` in `ManifoldUIModelManagement`) inject a
    /// closure here — closure-injection keeps `ManifoldUI` from importing the
    /// model-management module (CLAUDE.md dependency rule). `nil` (the default)
    /// leaves rows tappable only for the in-bubble flash deep-link.
    let onSelect: ((Citation) -> Void)?

    /// Per-bubble deep-link state. When an inline `[n]` marker is tapped the
    /// bubble sets the coordinator's `target`; this view reacts by expanding,
    /// scrolling the matching row into view, and flashing a transient highlight.
    /// `nil` when the bubble has no inline markers, so the disclosure behaves
    /// exactly as before.
    private var highlight: CitationHighlightCoordinator?

    @State private var isExpanded: Bool = false

    public init(citations: [Citation], onSelect: ((Citation) -> Void)? = nil) {
        self.citations = citations
        self.onSelect = onSelect
        self.highlight = nil
    }

    /// Internal initialiser used by ``MessageBubbleView`` to wire the in-bubble
    /// inline-marker deep-link. Kept non-public so the deep-link plumbing stays an
    /// implementation detail of the bubble.
    init(
        citations: [Citation],
        highlight: CitationHighlightCoordinator?,
        onSelect: ((Citation) -> Void)? = nil
    ) {
        self.citations = citations
        self.onSelect = onSelect
        self.highlight = highlight
    }

    public var body: some View {
        if citations.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                            CitationRow(
                                index: index + 1,
                                citation: citation,
                                isHighlighted: highlight?.target == index,
                                onSelect: onSelect
                            )
                            .id(index)
                        }
                    }
                    .padding(.top, 6)
                    .onChange(of: highlight?.target) { _, newTarget in
                        guard let newTarget else { return }
                        // Auto-expand so the scrolled-to row is visible, then bring
                        // it into view. The flash is driven by `isHighlighted`.
                        isExpanded = true
                        withAnimation(.easeInOut) {
                            proxy.scrollTo(newTarget, anchor: .center)
                        }
                    }
                }
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
    @Environment(\.manifoldTheme) private var theme
    let index: Int
    let citation: Citation
    /// Transient flash applied when an inline `[n]` marker deep-links here.
    var isHighlighted: Bool = false
    /// Optional host-supplied tap handler (deep-link into a richer source view).
    var onSelect: ((Citation) -> Void)? = nil

    var body: some View {
        // Wrap the card in a Button only when something can act on the tap —
        // an `onSelect` handler. When neither is set the row stays a plain,
        // non-interactive card (the historical look), so existing call sites
        // that pass no closure are unchanged.
        if let onSelect {
            Button {
                onSelect(citation)
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
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
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        // why: animate the fill so the deep-link flash eases in/out rather than
        // snapping, which reads as a deliberate "here it is" pulse.
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(index): \(citation.documentTitle), chunk \(citation.chunkIndex). \(citation.snippet)")
    }

    /// Quinary fill normally; the accent tint at low opacity while flashing.
    private var rowBackground: AnyShapeStyle {
        isHighlighted
            ? AnyShapeStyle(theme.accent.opacity(0.18))
            : AnyShapeStyle(.fill.quinary)
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
