import ManifoldInference

/// Registers the default set of backends with an InferenceService.
/// Call this at app startup after configuring ManifoldConfiguration.
///
/// ```swift
/// let service = InferenceService()
/// DefaultBackends.register(with: service)
/// ```
public enum DefaultBackends {

    // MARK: - Static Capability Queries
    //
    // Disposition (v0.48 packaging release, #1749): these statics describe
    // *this binary's compile-time contents*. Once backends can be registered
    // at runtime from companion packages (`quickStart(backends:)`), a
    // compile-time answer to "can I load this model?" is wrong — only the
    // build-introspection queries (`compiledBackends` / `buildProfile` /
    // `enabledTraits`) keep a meaningful compile-time semantic, and they are
    // documented as such. The load-capability queries are deprecated in favor
    // of the live registration state on `InferenceService`.

    /// The build/trait contract compiled into the current binary.
    ///
    /// Compile-time by definition — answers "what is in *this build*", not
    /// "what can the assembled service load". Backends registered at runtime
    /// from companion packages (#1749) are invisible here; use
    /// ``ManifoldInference/InferenceService/registeredBackendSnapshot()`` for
    /// load decisions.
    public static var compiledBackends: CompiledBackends { .current }

    /// The current binary's compile-time build profile.
    ///
    /// Compile-time by definition — see ``compiledBackends``.
    public static var buildProfile: BackendBuildProfile { compiledBackends.buildProfile }

    /// The inference traits compiled into the current binary.
    ///
    /// Compile-time by definition — see ``compiledBackends``.
    public static var enabledTraits: Set<BackendBuildTrait> { compiledBackends.traits }

    /// The local model types supported by this build, without requiring
    /// an `InferenceService` instance.
    @available(*, deprecated, message: "Compile-time reflection cannot see backends registered at runtime (quickStart(backends:), #1749). Use InferenceService.registeredBackendSnapshot().localModelTypes.")
    public static var supportedModelTypes: Set<ModelType> {
        compiledBackends.localModelTypes
    }

    /// Returns `true` if this build includes a backend for the given local model type.
    @available(*, deprecated, message: "Compile-time reflection cannot see backends registered at runtime (quickStart(backends:), #1749). Use InferenceService.compatibility(for:).isSupported.")
    public static func canLoad(modelType: ModelType) -> Bool {
        compiledBackends.compatibility(for: modelType).isSupported
    }

    /// Returns `true` if this build includes a backend for the given API provider.
    @available(*, deprecated, message: "Compile-time reflection cannot see backends registered at runtime (quickStart(backends:), #1749). Use InferenceService.compatibility(for:).isSupported.")
    public static func canLoad(provider: APIProvider) -> Bool {
        compiledBackends.compatibility(for: provider).isSupported
    }

    // MARK: - Pure Routing Helpers

    /// Returns the name of the backend class that would handle this model type,
    /// or nil if no backend is registered for it. Used for testing routing logic
    /// without instantiating hardware-dependent backends.
    static func backendTypeName(for modelType: ModelType) -> String? {
        switch modelType {
        case .gguf:
            #if Llama
            return "LlamaBackend"
            #else
            return nil
            #endif
        case .mlx:
            #if MLX
            return "MLXBackend"
            #else
            return nil
            #endif
        case .foundation:
            #if canImport(FoundationModels)
            return "FoundationBackend"
            #else
            return nil
            #endif
        }
    }

    static func backendTypeName(for provider: APIProvider) -> String? {
        switch provider {
        case .claude:                     return "ClaudeBackend"
        case .openAI, .lmStudio, .custom: return "OpenAIBackend"
        case .openAIResponses:            return "OpenAIResponsesBackend"
        case .ollama:                     return "OllamaBackend"
        }
    }

    // MARK: - Registration

    /// The default registrar fold. Order is significant only for
    /// `CloudBackends`, which calls `PinnedSessionDelegate.loadDefaultPins()`
    /// and must run before any URLSession factory. Local backends are
    /// independent.
    ///
    /// This is the *compiled-in* set only. Backends from companion packages
    /// (#1749) are not listed here — pass their registrars to
    /// ``ManifoldKit/ManifoldKit/quickStart(backends:configuration:seed:)``
    /// or call `register(with:)` on them directly after this fold.
    @MainActor
    public static let registrars: [any BackendRegistrar.Type] = [
        CloudBackends.self,
        MLXBackends.self,
        LlamaBackends.self,
        FoundationBackends.self,
    ]

    /// Registers every compiled-in backend family with `service` and returns
    /// how many backend capabilities (local model types + cloud providers) were
    /// actually wired.
    ///
    /// Since v0.48 the cloud registrars register unconditionally (the Ollama
    /// and CloudSaaS traits are retired), so the count is always non-zero —
    /// a bare count is a weak signal. Prefer inspecting
    /// ``ManifoldInference/InferenceService/registeredBackendSnapshot()``
    /// (`supportsLocalInference` / `cloudProviders`) as
    /// ``ManifoldKit/ManifoldKit/quickStart(configuration:)`` now does.
    @MainActor
    @discardableResult
    public static func register(with service: InferenceService) -> Int {
        for registrar in registrars {
            registrar.register(with: service)
        }
        return service.registeredBackendSnapshot().count
    }
}
