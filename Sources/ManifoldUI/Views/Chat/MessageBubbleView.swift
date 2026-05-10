import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A single chat message rendered as a bubble.
///
/// User messages are right-aligned with accent coloring, assistant messages
/// are left-aligned with a secondary background, and system messages are
/// centered and italic. Supports streaming state with a pulsing indicator.
/// When `isPinned` is `true`, a small pin icon is shown in the top-trailing
/// corner of the bubble to indicate the message is preserved when the
/// conversation history is trimmed to fit the context window.
public struct MessageBubbleView: View {

    public let message: ChatMessageRecord
    public let isStreaming: Bool
    public let isPinned: Bool
    public let linkPreviewProvider: LinkPreviewProvider?

    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(
        message: ChatMessageRecord,
        isStreaming: Bool,
        isPinned: Bool = false,
        linkPreviewProvider: LinkPreviewProvider? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.isPinned = isPinned
        self.linkPreviewProvider = linkPreviewProvider
    }

    // MARK: - Body

    public var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: spacerMinLength) }

            VStack(alignment: stackAlignment, spacing: 6) {
                bubbleContent
                    .frame(maxWidth: 700, alignment: alignment)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.accessibilityLabel(for: message))

                LinkPreviewAttachmentView(
                    text: message.content,
                    provider: linkPreviewProvider
                )
                .frame(maxWidth: 700, alignment: alignment)
            }

            if message.role == .assistant { Spacer(minLength: spacerMinLength) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .system:
            systemBubble
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessagePartsView(parts: message.contentParts, role: .user)

            HStack(spacing: 6) {
                if let statusText = Self.statusText(for: message) {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel(Self.statusAccessibilityLabel(for: message) ?? statusText)
                }

                timestampLabel
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Show the typing placeholder only when there is nothing at all to display
            // (no visible text, no thinking parts). Once a thinking part has been
            // inserted — even as an empty placeholder — render MessagePartsView so
            // ThinkingBlockView can show its "Thinking…" label in-bubble.
            let hasThinkingParts = message.contentParts.contains(where: { $0.thinkingContent != nil })
            if !message.hasVisibleContent && !hasThinkingParts && isStreaming {
                streamingPlaceholder
            } else {
                MessagePartsView(
                    parts: message.contentParts,
                    role: .assistant,
                    isStreaming: isStreaming,
                    messageID: message.id
                )
            }

            if isStreaming && message.hasVisibleContent {
                streamingIndicator
            }

            // Show citations only after streaming finishes so the disclosure
            // doesn't pop in/out while the bubble is still filling. Empty
            // citation arrays render an EmptyView via CitationsView.
            if !isStreaming, let citations = message.citations, !citations.isEmpty {
                CitationsView(citations: citations)
                    .padding(.top, 2)
            }

            if !isStreaming || message.hasVisibleContent {
                HStack(spacing: 6) {
                    timestampLabel
                        .foregroundStyle(.secondary)

                    if let completion = message.completionTokens {
                        Text("\(completion) tokens")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    private var systemBubble: some View {
        VStack(spacing: 4) {
            Text(message.content)
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            timestampLabel
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pin Indicator

    @ViewBuilder
    private var pinIndicator: some View {
        if isPinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .accessibilityLabel("Pinned message")
        }
    }

    // MARK: - Streaming Indicator

    private var streamingPlaceholder: some View {
        TypingIndicatorView()
            .padding(.vertical, 4)
    }

    private var streamingIndicator: some View {
        StreamingCursorView()
            .accessibilityLabel("Still generating")
    }

    // MARK: - Timestamp

    private var timestampLabel: some View {
        Text(message.timestamp, style: .time)
            .font(.caption)
    }

    // MARK: - Layout Helpers

    private var alignment: Alignment {
        switch message.role {
        case .user: .trailing
        case .assistant: .leading
        case .system: .center
        }
    }

    private var stackAlignment: HorizontalAlignment {
        switch message.role {
        case .user: .trailing
        case .assistant: .leading
        case .system: .center
        }
    }

    /// The minimum spacer length determines maximum bubble width.
    /// On compact (iPhone), bubbles take ~90% width; on regular (iPad/Mac), ~80%.
    private var spacerMinLength: CGFloat {
        sizeClass == .compact ? 20 : 60
    }

    // MARK: - Accessibility Contract

    /// Builds the VoiceOver label for a chat message bubble.
    ///
    /// Format: `"<Role> said: <content>"` (e.g. `"Assistant said: Hello"`).
    /// When the message contains non-text parts, appends short suffixes so
    /// VoiceOver users know audio/reasoning controls are available without
    /// reading hidden payloads inline.
    /// Exposed so the accessibility contract can be asserted by tests without
    /// duplicating the string-building logic.
    public static func accessibilityLabel(for message: ChatMessageRecord) -> String {
        let roleName: String = switch message.role {
        case .user: "User"
        case .assistant: "Assistant"
        case .system: "System"
        }
        let base = "\(roleName) said: \(message.content)"
        let hasThinking = message.contentParts.contains(where: { $0.thinkingContent != nil })
        let hasAudio = message.contentParts.contains(where: { $0.audioContent != nil })
        var suffixes: [String] = []
        if hasThinking { suffixes.append("Includes reasoning.") }
        if hasAudio { suffixes.append("Includes audio.") }
        return suffixes.isEmpty ? base : "\(base). \(suffixes.joined(separator: " "))"
    }

    public static func statusText(for message: ChatMessageRecord) -> String? {
        guard message.role == .user, let status = message.status else { return nil }
        return switch status {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .failed: "Failed"
        }
    }

    public static func statusAccessibilityLabel(for message: ChatMessageRecord) -> String? {
        guard message.role == .user, let status = message.status else { return nil }
        return switch status {
        case .sending: "Message sending"
        case .sent: "Message sent"
        case .failed: "Message failed to send"
        }
    }
}

// MARK: - Preview

#Preview("User Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .user, content: "Hello, tell me a story about a dragon.", sessionID: UUID()),
        isStreaming: false
    )
    .environment(ChatViewModel())
}

#Preview("Assistant Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .assistant, content: "Once upon a time, in a land far away, there lived a magnificent dragon named Ember.", sessionID: UUID()),
        isStreaming: false
    )
    .environment(ChatViewModel())
}

#Preview("Assistant Streaming") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .assistant, content: "Once upon a time...", sessionID: UUID()),
        isStreaming: true
    )
    .environment(ChatViewModel())
}

#Preview("System Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .system, content: "You are a creative storytelling assistant.", sessionID: UUID()),
        isStreaming: false
    )
}
