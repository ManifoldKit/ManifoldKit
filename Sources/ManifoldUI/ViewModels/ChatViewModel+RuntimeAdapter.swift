import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + RuntimeAdapter
//
// Thin forwarding shell. The full event-mapping implementation lives in
// `ChatGenerationCoordinator.handle(runtimeEvent:)`. Static helpers are kept
// here as forwarding wrappers so existing test callsites compile unchanged.

extension ChatViewModel {

    /// Forwards to the coordinator's event handler. All observable state
    /// mutations are performed by the coordinator through closure seams.
    @MainActor
    func handle(runtimeEvent event: ConversationEvent) async {
        await generationCoordinator.handle(runtimeEvent: event)
    }

    // MARK: - Static forwarding wrappers
    //
    // Tests call these as `ChatViewModel.appendVisibleText` / `writeThinkingPartialText`
    // directly. The implementations live on the coordinator; these wrappers preserve
    // the existing call sites without modification.

    static func appendVisibleText(_ batch: String, into msg: inout ChatMessageRecord) {
        ChatGenerationCoordinator.appendVisibleText(batch, into: &msg)
    }

    static func writeThinkingPartialText(_ partial: String, into msg: inout ChatMessageRecord) {
        ChatGenerationCoordinator.writeThinkingPartialText(partial, into: &msg)
    }

    // MARK: - Post-generation tasks

    /// Forwarding shell — delegates to the coordinator.
    func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        generationCoordinator.runPostGenerationTasks(message: message, session: session)
    }
}

private extension ChatViewModel {
    func markMostRecentUserMessageFailed() {
        guard let idx = messages.lastIndex(where: { $0.role == .user && $0.sessionID == activeSessionID }) else {
            return
        }
        messages[idx].status = .failed
    }
}
