import SwiftUI
import ManifoldInference

/// Internal message-history surface for ``ChatView``.
///
/// Keeps the public ``ChatView`` API focused on composition while this view owns
/// history rendering, empty-state placement, handoff chips, pagination, and
/// scroll coordination.
struct ChatHistoryView: View {

    @Environment(ChatViewModel.self) private var viewModel

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

    var body: some View {
        ScrollViewReader { proxy in
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
        }
        .frame(maxHeight: .infinity)
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

enum ChatHistoryScrollBehavior {

    static let bottomAnchorID = "chatBottom"

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
