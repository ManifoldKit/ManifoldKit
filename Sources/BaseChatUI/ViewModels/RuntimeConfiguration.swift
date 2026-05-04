import BaseChatRuntime
import BaseChatPersistenceSwiftData

extension ChatViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// ``BaseChatBootstrap``. Wires the persistence stores onto the view
    /// model.
    ///
    /// The shared ``ConversationRuntime`` is constructor-injected, not wired
    /// here — pass `runtime.conversationRuntime` to ``ChatViewModel/init`` so
    /// the runtime is available before the first observation occurs. Calling
    /// this method late (after construction) cannot retroactively replace the
    /// non-optional runtime stored on the view model.
    public func configure(runtime: BaseChatBootstrap) {
        configure(persistence: runtime.persistence)
    }

    /// Wires the bootstrap's runtimes into this ``ChatViewModel``.
    ///
    /// Equivalent to calling `configure(persistence:)` with the bootstrap's
    /// persistence layer and (if image generation is enabled)
    /// `configure(imageRuntime:)` with the bootstrap's
    /// ``BaseChatBootstrap/imageRuntime``.
    ///
    /// - Parameter bootstrap: The fully-constructed ``BaseChatBootstrap``
    ///   instance produced by ``BaseChatBootstrap/init(configuration:inferenceService:imageGenerationService:diagnostics:makeModelContainer:)``
    ///   or ``BaseChatBootstrap/build(configuration:inferenceService:imageGenerationService:diagnostics:makeModelContainer:)``.
    @MainActor
    public func configure(_ bootstrap: BaseChatBootstrap) {
        configure(persistence: bootstrap.persistence)
        if let imageRuntime = bootstrap.imageRuntime {
            configure(imageRuntime: imageRuntime)
        }
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
