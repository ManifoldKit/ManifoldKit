import BaseChatRuntime
import BaseChatPersistenceSwiftData

extension ChatViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatBootstrap``.
    public func configure(runtime: BaseChatBootstrap) {
        configure(persistence: runtime.persistence)
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
