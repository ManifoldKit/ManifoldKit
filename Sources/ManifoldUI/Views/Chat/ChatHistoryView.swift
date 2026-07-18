import SwiftUI
import ManifoldInference
#if os(macOS)
import AppKit
#endif

/// Internal message-history surface for ``ChatView``.
///
/// Keeps the public ``ChatView`` API focused on composition while this view owns
/// history rendering, empty-state placement, handoff chips, pagination, and
/// scroll coordination.
struct ChatHistoryView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.manifoldTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Optional host-supplied per-message renderer. When set, it is given the
    /// chance to render each row; it falls through to the built-in bubble via
    /// `params.defaultMessageView()`. Injected with `.chatMessageRenderer(_:)`.
    @Environment(\.chatMessageRenderer) private var messageRenderer

    /// Builder for a host-supplied empty-state view, invoked at render time
    /// (not stored eagerly) so it reflects state mutated after `ChatView` was
    /// constructed.
    let emptyStateBuilder: (() -> AnyView)?
    let linkPreviewProvider: LinkPreviewProvider?
    let contextMenuItemsBuilder: ((ChatMessage) -> AnyView)?
    let customKindRenderer: ((ChatMessage) -> AnyView)?

    /// Tracks whether the scroll position is far enough from the bottom
    /// anchor that the scroll-to-bottom control should be offered. Updated
    /// from `.onScrollGeometryChange` via the pure
    /// `ChatHistoryScrollBehavior.isScrolledAwayFromBottom` helper (Unit 2
    /// §L1) so the visibility decision itself stays unit-testable without a
    /// live `ScrollView`.
    @State private var isScrolledAwayFromBottom = false

    /// The control only offers to jump back to the live edge while a turn is
    /// actively streaming and the user has scrolled away from it — surfacing
    /// it while idle and already at the bottom would just be visual noise.
    private var showsScrollToBottomControl: Bool {
        isScrolledAwayFromBottom && viewModel.isGenerating
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if viewModel.hasOlderMessages {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .onAppear {
                                    ChatHistoryScrollBehavior.loadOlderAndRestore(
                                        viewModel: viewModel,
                                        proxy: proxy
                                    )
                                }
                        }

                        if viewModel.messages.isEmpty && !viewModel.isGenerating {
                            ChatHistoryEmptyPlaceholder(customContentBuilder: emptyStateBuilder)
                        }

                        // why: iterate `messages` directly (ChatMessage is
                        // Identifiable) instead of materializing a fresh
                        // `enumerated()` tuple array on every body eval — that array
                        // was an O(N) allocation per streaming batch (~30/sec). The
                        // only index consumer was the handoff chip, which needs the
                        // PREVIOUS message; we precompute the handoff boundaries in
                        // one O(N) pass keyed by message id so no per-row scan is
                        // reintroduced.
                        let handoffBoundaries = ChatHistoryHandoffResolver.boundaries(
                            messages: viewModel.messages,
                            session: viewModel.activeSession
                        )
                        ForEach(viewModel.messages) { message in
                            messageRow(message: message, handoffChip: handoffBoundaries[message.id])
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatHistoryScrollBehavior.bottomAnchorID)
                    }
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    ChatHistoryScrollBehavior.isScrolledAwayFromBottom(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height
                    )
                } action: { _, newValue in
                    isScrolledAwayFromBottom = newValue
                }
                .onAppear {
                    _ = ChatHistoryScrollBehavior.consumeScrollToMessageRequest(
                        viewModel: viewModel,
                        proxy: proxy
                    )
                }
                .onChange(of: viewModel.scrollToMessageRequest?.requestID) {
                    _ = ChatHistoryScrollBehavior.consumeScrollToMessageRequest(
                        viewModel: viewModel,
                        proxy: proxy
                    )
                }
                .onChange(of: viewModel.messages.count) {
                    if ChatHistoryScrollBehavior.consumeScrollToMessageRequest(
                        viewModel: viewModel,
                        proxy: proxy
                    ) { return }

                    if !viewModel.isLoadingOlderMessages {
                        ChatHistoryScrollBehavior.scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.messages.last?.content) {
                    if ChatHistoryScrollBehavior.consumeScrollToMessageRequest(
                        viewModel: viewModel,
                        proxy: proxy
                    ) { return }
                    ChatHistoryScrollBehavior.scrollToBottom(proxy: proxy)
                }

                if showsScrollToBottomControl {
                    ScrollToBottomButton(reduceMotion: reduceMotion) {
                        ChatHistoryScrollBehavior.scrollToBottom(proxy: proxy)
                    }
                    .environment(\.manifoldTheme, theme)
                    .padding(12)
                    .transition(ScrollToBottomButton.appearanceTransition(reduceMotion: reduceMotion))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .animation(
            ScrollToBottomButton.appearanceAnimation(reduceMotion: reduceMotion),
            value: showsScrollToBottomControl
        )
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, handoffChip: HandoffChipView?) -> some View {
        if let handoffChip {
            handoffChip
        }

        // A host renderer (if any) gets first refusal on the row; it can take
        // over specific messages and defer the rest to the built-in bubble via
        // `params.defaultMessageView()`. Without a renderer this is the default
        // bubble, unchanged.
        let params = ChatMessageRenderParameters(
            message: message,
            isStreaming: isMessageStreaming(message),
            isPinned: viewModel.isMessagePinned(id: message.id),
            session: viewModel.activeSession,
            linkPreviewProvider: linkPreviewProvider,
            customKindRenderer: customKindRenderer
        )
        let bubble = messageRenderer?(params) ?? params.defaultMessageView()

        if let contextMenuItemsBuilder {
            bubble
                .messageActionMenu(message: message, viewModel: viewModel) { msg in
                    contextMenuItemsBuilder(msg)
                }
                .id(message.id)
        } else {
            bubble
                .messageActionMenu(message: message, viewModel: viewModel)
                .id(message.id)
        }
    }

    private func isMessageStreaming(_ message: ChatMessage) -> Bool {
        viewModel.isGenerating
        && message.role == .assistant
        && message.id == viewModel.messages.last?.id
    }
}

struct ChatHistoryEmptyPlaceholder: View {

    /// Invoked here, inside `body`, rather than stored as a pre-built `AnyView` —
    /// this is what makes the empty state reflect state mutated after `ChatView`
    /// was constructed (SwiftUI's Observation tracking registers property reads
    /// that happen during body evaluation, wherever on the call stack they occur).
    let customContentBuilder: (() -> AnyView)?

    var body: some View {
        Group {
            if let customContentBuilder {
                customContentBuilder()
            } else {
                Text("Send a message to start chatting.")
                    .foregroundStyle(.tertiary)
                    .font(.body)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

enum ChatHistoryHandoffResolver {

    /// Computes, in a single O(N) pass, the handoff chip to render *above* each
    /// message — keyed by the message's id.
    ///
    /// why: `ChatHistoryView` used to call ``chip(at:messages:session:)`` per
    /// row, and each call did its own adjacency lookup. Iterating `messages`
    /// directly (rather than `enumerated()`) means rows no longer carry their
    /// index, so we resolve every boundary up front. Output is byte-for-byte
    /// equivalent to calling ``chip(at:messages:session:)`` for each index.
    @MainActor
    static func boundaries(
        messages: [ChatMessage],
        session: ChatSession?
    ) -> [UUID: HandoffChipView] {
        guard let session, messages.count > 1 else { return [:] }
        var result: [UUID: HandoffChipView] = [:]
        for index in 1..<messages.count {
            if let chip = chip(at: index, messages: messages, session: session) {
                result[messages[index].id] = chip
            }
        }
        return result
    }

    /// Returns a ``HandoffChipView`` when adjacent persisted messages transition
    /// between two agents resolved from the active session.
    @MainActor
    static func chip(
        at index: Int,
        messages: [ChatMessage],
        session: ChatSession?
    ) -> HandoffChipView? {
        guard index > 0,
              let session,
              index < messages.count
        else { return nil }

        let current = messages[index]
        let previous = messages[index - 1]
        guard let currentAgentID = current.agentID,
              let previousAgentID = previous.agentID,
              currentAgentID != previousAgentID
        else { return nil }

        let agents = session.agents
        guard let toAgent = agents.first(where: { $0.id == currentAgentID }),
              let fromAgent = agents.first(where: { $0.id == previousAgentID })
        else { return nil }

        return HandoffChipView(from: fromAgent, to: toAgent)
    }
}

/// Floating control (Unit 2 §L1) that jumps the transcript back to the live
/// edge. Only shown by ``ChatHistoryView`` while the user has scrolled away
/// from the bottom during an active stream.
struct ScrollToBottomButton: View {

    @Environment(\.manifoldTheme) private var theme
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to latest message")
        .accessibilityAddTraits(.isButton)
        .manifoldGlass(theme, in: Circle())
        .clipShape(Circle())
        #if os(macOS)
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }

    /// The transition used when the control appears/disappears. Pure,
    /// `View`-free so it can be asserted directly (mirrors
    /// `StreamingIndicatorReduceMotionTests`'s static-helper pattern):
    /// Reduce Motion drops the scale/opacity transition down to a plain
    /// opacity crossfade so nothing visibly moves.
    static func appearanceTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85))
    }

    /// The animation driving ``appearanceTransition(reduceMotion:)``. `nil`
    /// under Reduce Motion disables animation entirely (an instant swap),
    /// matching the "static under Reduce Motion" contract spec §9 sets for
    /// every shimmer/live-state surface in this refresh.
    static func appearanceAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}

enum ChatHistoryScrollBehavior {

    static let bottomAnchorID = "chatBottom"

    /// How far (in points) the scroll offset must sit from the bottom edge
    /// before the scroll-to-bottom control offers to jump back. Small enough
    /// that a user resting at the very edge never sees it flicker in.
    static let scrolledAwayThreshold: CGFloat = 80

    /// `true` when the scroll offset is far enough from the bottom edge that
    /// the scroll-to-bottom control should be offered. Pure function over
    /// `ScrollGeometry`'s three scalar components (not the SwiftUI type
    /// itself) so both branches are directly unit-testable without a live
    /// `ScrollView`.
    static func isScrolledAwayFromBottom(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        threshold: CGFloat = scrolledAwayThreshold
    ) -> Bool {
        let distanceFromBottom = contentHeight - containerHeight - offsetY
        return distanceFromBottom > threshold
    }

    @MainActor
    static func loadOlderAndRestore(viewModel: ChatViewModel, proxy: ScrollViewProxy) {
        Task { @MainActor in
            guard let anchorID = await viewModel.loadOlderMessages() else { return }
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    @MainActor
    @discardableResult
    static func consumeScrollToMessageRequest(
        viewModel: ChatViewModel,
        proxy: ScrollViewProxy
    ) -> Bool {
        guard let request = viewModel.scrollToMessageRequest else { return false }
        guard canConsumeScrollToMessageRequest(request, in: viewModel.messages) else { return false }

        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(request.messageID, anchor: request.anchor.unitPoint)
        }
        viewModel.consumeScrollToMessageRequest(request)
        return true
    }

    static func canConsumeScrollToMessageRequest(
        _ request: ChatScrollToMessageRequest,
        in messages: [ChatMessage]
    ) -> Bool {
        messages.contains(where: { $0.id == request.messageID })
    }

    @MainActor
    static func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private extension Optional where Wrapped == ChatMessageScrollAnchor {
    var unitPoint: UnitPoint? {
        switch self {
        case .some(.top):
            .top
        case .some(.center):
            .center
        case .some(.bottom):
            .bottom
        case nil:
            nil
        }
    }
}
