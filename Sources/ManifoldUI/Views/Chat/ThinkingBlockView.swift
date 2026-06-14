import SwiftUI

/// A collapsible disclosure group displaying model reasoning content.
///
/// While `isThinkingStreaming` is true the view renders a collapsed disclosure
/// group whose label is `"Thinking… <inline preview>"` — the latest few lines
/// of partial reasoning text streamed in via the thinking batcher in
/// ``GenerationQueue``. Expanding the group reveals the full
/// accumulated text. Once `isThinkingStreaming` flips to false the disclosure
/// group switches to its finalized "Reasoning" label, still collapsed by
/// default. This is intentionally decoupled from the overall message
/// streaming flag — completed reasoning should become expandable even while
/// visible tokens are still arriving.
struct ThinkingBlockView: View {
    let text: String
    /// True only while the reasoning block itself is still open (i.e. no
    /// `.thinkingCompleted` event has been received yet). Distinct from the
    /// overall message `isStreaming` flag.
    let isThinkingStreaming: Bool

    @State private var isExpanded = false

    /// Shows the trailing line of partial reasoning text inline next to the
    /// "Thinking…" label so users see live progress without expanding the
    /// disclosure group. Multi-line reasoning is collapsed to its last line
    /// to keep bubble height stable while tokens stream in.
    private var inlinePreview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        return String(lastLine.suffix(80))
    }

    var body: some View {
        if isThinkingStreaming {
            // `.accessibilitySortPriority` is intentionally omitted — SwiftUI
            // renders parts in document order, so ThinkingBlockView (placed before
            // the text parts in MessagePartsView's ForEach) is already visited
            // first by VoiceOver.
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(text.isEmpty ? " " : text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Label("Thinking…", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !inlinePreview.isEmpty {
                        Text(inlinePreview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityHidden(true)
                    }
                }
            }
            // Intentionally omit `.accessibilityValue(text)` here — `text`
            // updates every ~33ms while reasoning streams, which floods
            // VoiceOver with re-announcements of a value the user has not
            // asked to hear yet. Expanding the disclosure group exposes the
            // accumulated text via the inner `Text` for assistive reading;
            // the static "Reasoning in progress" label is enough for the
            // collapsed state. Hosts that *do* want paced spoken progress
            // should drive `AccessibilityAnnouncer` (coalesce + rate-limit +
            // priority) from the token stream — the supported path for
            // announcing streaming output without flooding assistive tech.
            .accessibilityLabel("Reasoning in progress")
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Reasoning")
            .accessibilityHint(isExpanded ? "Double-tap to collapse." : "Double-tap to expand.")
        }
    }
}

#Preview("Completed") {
    ThinkingBlockView(
        text: "Let me think about this step by step. First I'll consider the constraints...",
        isThinkingStreaming: false
    )
    .padding()
}

#Preview("Streaming with preview") {
    ThinkingBlockView(
        text: "Let me think about this step by step. First I'll consider the constraints",
        isThinkingStreaming: true
    )
    .padding()
}

#Preview("Streaming empty") {
    ThinkingBlockView(text: "", isThinkingStreaming: true)
        .padding()
}
