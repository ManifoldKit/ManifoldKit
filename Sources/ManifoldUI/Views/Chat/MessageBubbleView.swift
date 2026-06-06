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

    /// Optional renderer for non-user-visible kind records. When `nil` (the default),
    /// records with `kind.isUserVisible == false` render as `EmptyView`. Hosts can
    /// supply a closure here (via ``ChatView``) to render memory or annotation bubbles.
    public let customKindRenderer: ((ChatMessageRecord) -> AnyView)?

    /// The session this message belongs to. Used to resolve ``ChatMessageRecord/agentID``
    /// against ``ChatSessionRecord/agents`` for per-agent badge rendering. When `nil`
    /// (or when the message's `agentID` does not resolve), the bubble falls back to
    /// role-based rendering. This is the architect-flagged dangling-reference path —
    /// an agent may have been deleted out from under a message that still references
    /// it, and the UI must not crash or surface "unknown agent" text in that case.
    public let session: ChatSessionRecord?

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Semantic styling tokens (per-role background, padding, radius, spacing,
    /// fonts). Defaults to ``ChatTheme/standard``, which reproduces the
    /// historical look, so reading the theme is non-breaking.
    @Environment(\.chatTheme) private var theme

    /// The bubble chrome style. The default ``PlainMessageBubbleStyle`` reads
    /// ``ChatTheme``, so tokens (Layer 1) and styles (Layer 2) compose.
    @Environment(\.messageBubbleStyle) private var bubbleStyle

    /// Dynamic Type multiplier (1 at the default content size category) applied
    /// to themed spacing at this consumption site. Bubble padding and corner
    /// radius are scaled inside the style body; the inner spacings are scaled
    /// here where they are consumed.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    public init(
        message: ChatMessageRecord,
        isStreaming: Bool,
        isPinned: Bool = false,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        customKindRenderer: ((ChatMessageRecord) -> AnyView)? = nil,
        session: ChatSessionRecord? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.isPinned = isPinned
        self.linkPreviewProvider = linkPreviewProvider
        self.customKindRenderer = customKindRenderer
        self.session = session
    }

    // MARK: - Agent Resolution

    /// Resolves the message's `agentID` against the supplied session's agent
    /// registry. Returns `nil` when there is no agentID, no session, or when
    /// the agent has been deleted from the session (dangling reference).
    var resolvedAgent: Agent? {
        guard let agentID = message.agentID,
              let session
        else { return nil }
        return session.agents.first(where: { $0.id == agentID })
    }

    // MARK: - Body

    public var body: some View {
        // Non-user-visible kinds (memory, annotation, toolResult, custom) are
        // hidden by default. Hosts can supply a customKindRenderer to override.
        if message.kind.isUserVisible {
            chatBubble
        } else if let renderer = customKindRenderer {
            renderer(message)
        }
        // else: EmptyView is the implicit fallthrough in a @ViewBuilder body.
    }

    @ViewBuilder
    private var chatBubble: some View {
        HStack {
            if message.role == .user { Spacer(minLength: spacerMinLength) }

            VStack(alignment: stackAlignment, spacing: theme.bubbleStackSpacing * typeScale) {
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
        // The bubble chrome (padding/background/shape) is delegated to the
        // resolved `MessageBubbleStyle`; the inner layout stays here so a custom
        // style never has to re-implement the content.
        styledBubble(role: .user) {
            VStack(alignment: .trailing, spacing: theme.contentSpacing * typeScale) {
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
        }
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    private var assistantBubble: some View {
        styledBubble(role: .assistant) {
            assistantBubbleContent
        }
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    @ViewBuilder
    private var assistantBubbleContent: some View {
        VStack(alignment: .leading, spacing: theme.contentSpacing * typeScale) {
            // Per-agent badge when the message attribution resolves to a real
            // agent in the session registry. When `agentID` is nil OR refers
            // to a deleted agent, this falls through to the standard role
            // render — no crash, no "unknown agent" placeholder.
            if let agent = resolvedAgent {
                agentBadge(for: agent)
            }
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
    }

    /// Wraps inner bubble content in the resolved ``MessageBubbleStyle``. The
    /// default style draws today's padding/background/shape from ``ChatTheme``;
    /// `.iMessage`/`.card` (or a custom style) restructure it.
    @ViewBuilder
    private func styledBubble(role: MessageRole, @ViewBuilder content: () -> some View) -> some View {
        ResolvedMessageBubble(
            style: bubbleStyle,
            configuration: MessageBubbleConfiguration(
                content: AnyView(content()),
                role: role,
                isStreaming: isStreaming
            )
        )
    }

    private var systemBubble: some View {
        // System notices are centered text, not a chrome'd bubble, so they read
        // theme metrics/fonts directly rather than routing through the style.
        VStack(spacing: theme.contentSpacing * typeScale) {
            Text(message.content)
                .font(theme.bubbleFont)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            timestampLabel
                .foregroundStyle(.tertiary)
        }
        .padding(theme.bubblePadding * typeScale)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Agent Badge

    /// Avatar + name pill identifying which agent in the session produced this
    /// message. Color is derived deterministically from the agent's UUID so two
    /// different agents look visually distinct without per-agent theming work.
    @ViewBuilder
    private func agentBadge(for agent: Agent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "person.circle.fill")
                .font(.caption)
                .foregroundStyle(Self.agentColor(for: agent.id))
            Text(agent.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent: \(agent.name)")
        .accessibilityIdentifier("agent-badge-\(agent.id.uuidString)")
    }

    /// Deterministic colour derived from a hash of the agent UUID. Cycles
    /// through a small palette so two different agents look distinct. Pure
    /// function: same UUID always maps to the same colour across runs.
    static func agentColor(for id: UUID) -> Color {
        // Stable palette — keep narrow so contrast against the assistant
        // bubble background stays acceptable.
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .mint, .brown]
        var hasher = Hasher()
        hasher.combine(id)
        // hasher.finalize() is platform-dependent but stable within a process;
        // for cross-process determinism we hash the UUID's bytes instead.
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return palette[abs(sum) % palette.count]
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
            .font(theme.metadataFont)
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
