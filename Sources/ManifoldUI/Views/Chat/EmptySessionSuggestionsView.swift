import SwiftUI

/// Suggestion-chip content for the empty-session placeholder
/// (`docs/UI-REFRESH-2026.md` §6A — "Empty session shows suggestion chips
/// via the existing `chatEmptyState` slot").
///
/// This is the content a host passes to ``ChatView/chatEmptyState(_:)`` —
/// it does not replace or extend that seam itself (`ChatView.swift` is
/// owned by the L1 tranche). Deliberately "dumb" (no `@Environment` reads
/// beyond the theme, mirroring ``ToolInvocationView``/``HandoffChipView``):
/// tapping a chip invokes ``onSelectSuggestion`` with the suggestion text,
/// leaving the host to decide what "select a suggestion" means (stage into
/// ``ChatViewModel/inputText`` and send immediately, or something else). A
/// typical host wiring:
///
/// ```swift
/// .chatEmptyState {
///     EmptySessionSuggestionsView(suggestions: suggestions) { suggestion in
///         viewModel.inputText = suggestion
///         Task { await viewModel.sendMessage() }
///     }
/// }
/// ```
public struct EmptySessionSuggestionsView: View {

    @Environment(\.manifoldTheme) private var theme

    let title: String
    let suggestions: [String]
    let onSelectSuggestion: (String) -> Void

    public init(
        title: String = "Send a message to start chatting.",
        suggestions: [String],
        onSelectSuggestion: @escaping (String) -> Void = { _ in }
    ) {
        self.title = title
        self.suggestions = suggestions
        self.onSelectSuggestion = onSelectSuggestion
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(theme.type.body)
                .foregroundStyle(theme.ink3)

            if !suggestions.isEmpty {
                FlowChipLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        chip(suggestion)
                    }
                }
                .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-session-suggestions")
    }

    private func chip(_ suggestion: String) -> some View {
        Button {
            onSelectSuggestion(suggestion)
        } label: {
            Text(suggestion)
                .font(theme.type.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("empty-session-suggestion-chip")
    }
}

/// Minimal wrapping HStack/VStack flow layout for suggestion chips of
/// unknown, varying width. `Layout`-conforming so chip count/width can vary
/// freely without the caller precomputing rows.
struct FlowChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    EmptySessionSuggestionsView(suggestions: [
        "Summarize this document",
        "Draft a reply",
        "Explain a concept",
    ])
}
