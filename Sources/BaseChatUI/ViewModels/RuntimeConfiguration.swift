import BaseChatCore

extension ChatViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatRuntime``.
    public func configure(runtime: BaseChatRuntime) {
        configure(persistence: runtime.persistence)
    }
}

extension SessionManagerViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatRuntime``.
    public func configure(runtime: BaseChatRuntime) {
        configure(
            persistence: runtime.persistence,
            diagnostics: runtime.diagnostics
        )
    }
}
