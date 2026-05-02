import BaseChatRuntime
import BaseChatPersistenceSwiftData

extension ChatViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatBootstrap``. Wires both the persistence stores and the
    /// shared ``ConversationRuntime`` instance so send/regenerate/edit/cancel
    /// route through the runtime by default.
    public func configure(runtime: BaseChatBootstrap) {
        configure(persistence: runtime.persistence)
        configure(conversationRuntime: runtime.conversationRuntime)
    }
}

extension SessionManagerViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatBootstrap``. Schedules the initial session load so the UI
    /// matches pre-Phase-1.0 behavior. Direct callers of
    /// ``configure(persistence:autoLoad:diagnostics:)`` must opt in explicitly.
    public func configure(runtime: BaseChatBootstrap) {
        configure(
            persistence: runtime.persistence,
            autoLoad: true,
            diagnostics: runtime.diagnostics
        )
    }
}
