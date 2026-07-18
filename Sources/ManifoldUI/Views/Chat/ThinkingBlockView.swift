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

    @Environment(\.thinkingBlockStyle) private var style

    @State private var isExpanded = false
    /// Wall-clock time the block started streaming, captured the first time
    /// `isThinkingStreaming` is observed `true`. Best-effort — a block loaded
    /// already-settled from history (this view never saw it streaming) never
    /// sets this, so ``ThinkingBlockStyle`` sees `duration == 0` (see
    /// ``ThinkingBlockState``'s doc comment on that convention).
    @State private var streamStartDate: Date?
    @State private var settledDuration: TimeInterval = 0

    private var state: ThinkingBlockState {
        if isThinkingStreaming { return .streaming }
        return isExpanded ? .expanded(duration: settledDuration) : .settled(duration: settledDuration)
    }

    var body: some View {
        // `.accessibilitySortPriority` is intentionally omitted — SwiftUI
        // renders parts in document order, so ThinkingBlockView (placed before
        // the text parts in MessagePartsView's ForEach) is already visited
        // first by VoiceOver.
        //
        // Intentionally omit `.accessibilityValue(text)` while streaming —
        // `text` updates every ~33ms which would flood VoiceOver with
        // re-announcements of a value the user has not asked to hear yet.
        // Expanding the disclosure group exposes the accumulated text via the
        // inner `Text` for assistive reading; the static "Reasoning in
        // progress" label is enough for the collapsed state. Paced spoken
        // progress for the *visible* token stream is handled automatically:
        // `ChatGenerationCoordinator` drives `AccessibilityAnnouncer`
        // (coalesce + rate-limit + priority) from `.tokenEmitted`, so
        // streaming output is announced without flooding assistive tech.
        // Reasoning deltas deliberately stay out of that pipeline.
        ResolvedThinkingBlock(
            style: style,
            configuration: ThinkingBlockConfiguration(
                state: state,
                text: text,
                toggleExpanded: { isExpanded.toggle() }
            )
        )
        .onChange(of: isThinkingStreaming, initial: true) { _, streaming in
            if streaming {
                if streamStartDate == nil { streamStartDate = Date() }
            } else if let start = streamStartDate {
                settledDuration = Date().timeIntervalSince(start)
            }
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
