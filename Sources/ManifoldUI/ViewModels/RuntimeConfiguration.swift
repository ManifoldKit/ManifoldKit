import ManifoldRuntime

extension ChatViewModel {
    /// Canonical bootstrap-wiring entry point.
    ///
    /// Wires the bootstrap's persistence stores, endpoint store, and (if
    /// image generation is enabled) the image runtime onto this view model.
    /// The shared ``ConversationRuntime`` is constructor-injected, not wired
    /// here — pass `bootstrap.conversationRuntime` to ``ChatViewModel/init``
    /// so the runtime is available before the first observation occurs.
    /// Calling this method late (after construction) cannot retroactively
    /// replace the non-optional runtime stored on the view model.
    ///
    /// - Parameter bootstrap: The fully-constructed runtime bootstrap.
    @MainActor
    public func configure(bootstrap: any ChatRuntimeBootstrap) {
        configure(persistence: bootstrap.persistenceStores)
        configure(endpointStore: bootstrap.apiEndpointStore)
        if let imageRuntime = bootstrap.imageGenerationRuntime {
            configure(imageRuntime: imageRuntime)
        }
    }

    /// Preferred bootstrap path for apps that assemble shared services through
    /// a ``ChatRuntimeBootstrap``. Wires the persistence and endpoint stores
    /// onto the view model.
    ///
    /// Behaviour preserved as a deprecation shim — pre-I6 this overload did
    /// not wire `imageGenerationRuntime`. New callers should use
    /// ``configure(bootstrap:)``, which wires the image runtime when present.
    @available(*, deprecated, renamed: "configure(bootstrap:)", message: "Use configure(bootstrap:) — it also wires imageGenerationRuntime when the bootstrap exposes one.")
    @MainActor
    public func configure(runtime: any ChatRuntimeBootstrap) {
        configure(persistence: runtime.persistenceStores)
        configure(endpointStore: runtime.apiEndpointStore)
    }

    /// Wires the bootstrap's runtimes into this ``ChatViewModel``.
    ///
    /// Equivalent to ``configure(bootstrap:)``. Retained as a deprecation
    /// shim for one minor while adopters migrate.
    @available(*, deprecated, renamed: "configure(bootstrap:)", message: "Use configure(bootstrap:) — same behaviour, more explicit argument label.")
    @MainActor
    public func configure(_ bootstrap: any ChatRuntimeBootstrap) {
        configure(bootstrap: bootstrap)
    }
}

extension SessionManagerViewModel {
    /// Preferred bootstrap path for apps that assemble shared services through
    /// a ``ChatRuntimeBootstrap``. Schedules the initial session load so the UI
    /// matches pre-Phase-1.0 behavior. Direct callers of
    /// ``configure(persistence:autoLoad:diagnostics:)`` must opt in explicitly.
    public func configure(bootstrap: any ChatRuntimeBootstrap) {
        configure(
            persistence: bootstrap.persistenceStores,
            autoLoad: true,
            diagnostics: bootstrap.diagnosticsService
        )
    }

    /// Deprecated shim kept for one minor.
    @available(*, deprecated, renamed: "configure(bootstrap:)", message: "Use configure(bootstrap:) — same behaviour.")
    public func configure(runtime: any ChatRuntimeBootstrap) {
        configure(bootstrap: runtime)
    }
}
