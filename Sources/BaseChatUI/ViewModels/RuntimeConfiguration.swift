import BaseChatRuntime

extension ChatViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// a ``ChatRuntimeBootstrap``. Wires the persistence and endpoint stores
    /// onto the view model.
    ///
    /// The shared ``ConversationRuntime`` is constructor-injected, not wired
    /// here — pass `runtime.conversationRuntime` to ``ChatViewModel/init`` so
    /// the runtime is available before the first observation occurs. Calling
    /// this method late (after construction) cannot retroactively replace the
    /// non-optional runtime stored on the view model.
    public func configure(runtime: any ChatRuntimeBootstrap) {
        configure(persistence: runtime.persistenceStores)
        configure(endpointStore: runtime.apiEndpointStore)
    }

    /// Wires the bootstrap's runtimes into this ``ChatViewModel``.
    ///
    /// Equivalent to calling `configure(persistence:)` with the bootstrap's
    /// persistence layer and (if image generation is enabled)
    /// `configure(imageRuntime:)` with the bootstrap's
    /// ``ChatRuntimeBootstrap/imageGenerationRuntime``.
    ///
    /// - Parameter bootstrap: The fully-constructed runtime bootstrap.
    @MainActor
    public func configure(_ bootstrap: any ChatRuntimeBootstrap) {
        configure(persistence: bootstrap.persistenceStores)
        configure(endpointStore: bootstrap.apiEndpointStore)
        if let imageRuntime = bootstrap.imageGenerationRuntime {
            configure(imageRuntime: imageRuntime)
        }
    }
}

extension SessionManagerViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// a ``ChatRuntimeBootstrap``. Schedules the initial session load so the UI
    /// matches pre-Phase-1.0 behavior. Direct callers of
    /// ``configure(persistence:autoLoad:diagnostics:)`` must opt in explicitly.
    public func configure(runtime: any ChatRuntimeBootstrap) {
        configure(
            persistence: runtime.persistenceStores,
            autoLoad: true,
            diagnostics: runtime.diagnosticsService
        )
    }
}
