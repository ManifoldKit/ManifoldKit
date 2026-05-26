import SwiftUI
import ManifoldInference

/// Internal message-history surface for ``ChatView``.
///
/// Keeps the public ``ChatView`` API focused on composition while this view owns
/// history rendering, empty-state placement, handoff chips, pagination, and
/// scroll coordination.
struct ChatHistoryView: View {

    @Environment(ChatViewModel.self) private var viewModel

    let customEmptyPlaceholder: AnyView?
    let linkPreviewProvider: LinkPreviewProvider?
    let contextMenuItemsBuilder: ((ChatMessageRecord) -> AnyView)?
    let customKindRenderer: ((ChatMessageRecord) -> AnyView)?

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
                        ChatHistoryEmptyPlaceholder(customContent: customEmptyPlaceholder)
                    }

                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        messageRow(at: index, message: message)
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
    private func messageRow(at index: Int, message: ChatMessageRecord) -> some View {
        if let chip = ChatHistoryHandoffResolver.chip(
            at: index,
            messages: viewModel.messages,
            session: viewModel.activeSession
        ) {
            chip
        }

        let bubble = MessageBubbleView(
            message: message,
            isStreaming: isMessageStreaming(message),
            isPinned: viewModel.isMessagePinned(id: message.id),
            linkPreviewProvider: linkPreviewProvider,
            customKindRenderer: customKindRenderer,
            session: viewModel.activeSession
        )

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

    private func isMessageStreaming(_ message: ChatMessageRecord) -> Bool {
        viewModel.isGenerating
        && message.role == .assistant
        && message.id == viewModel.messages.last?.id
    }
}

struct ChatHistoryEmptyPlaceholder: View {

    let customContent: AnyView?

    var body: some View {
        Group {
            if let customContent {
                customContent
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

    /// Returns a ``HandoffChipView`` when adjacent persisted messages transition
    /// between two agents resolved from the active session.
    @MainActor
    static func chip(
        at index: Int,
        messages: [ChatMessageRecord],
        session: ChatSessionRecord?
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

        return HandoffChipView(from: fromAgent, to: toAgent, payload: nil)
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
        in messages: [ChatMessageRecord]
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
