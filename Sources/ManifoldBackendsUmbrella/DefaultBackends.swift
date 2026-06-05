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

    /// The build/trait contract compiled into the current binary.
    public static var compiledBackends: CompiledBackends { .current }

    /// The current binary's runtime-visible build profile.
    public static var buildProfile: BackendBuildProfile { compiledBackends.buildProfile }

    /// The inference traits compiled into the current binary.
    public static var enabledTraits: Set<BackendBuildTrait> { compiledBackends.traits }

    /// The local model types supported by this build, without requiring
    /// an `InferenceService` instance.
    ///
    /// Useful for static checks before service construction (e.g., in unit tests
    /// or feature-flag evaluation at app startup).
    public static var supportedModelTypes: Set<ModelType> {
        compiledBackends.localModelTypes
    }

    /// Returns `true` if this build includes a backend for the given local model type.
    public static func canLoad(modelType: ModelType) -> Bool {
        compiledBackends.compatibility(for: modelType).isSupported
    }

    /// Returns `true` if this build includes a backend for the given API provider.
    public static func canLoad(provider: APIProvider) -> Bool {
        compiledBackends.compatibility(for: provider).isSupported
    }

    // MARK: - Pure Routing Helpers

    /// Returns the name of the backend class that would handle this model type,
    /// or nil if no backend is registered for it. Used for testing routing logic
    /// without instantiating hardware-dependent backends.
    static func backendTypeName(for modelType: ModelType) -> String? {
        switch modelType {
        #if Llama
        case .gguf:       return "LlamaBackend"
        #endif
        #if MLX
        case .mlx:        return "MLXBackend"
        #endif
        #if canImport(FoundationModels)
        case .foundation: return "FoundationBackend"
        #endif
        default:          return nil
        }
    }

    static func backendTypeName(for provider: APIProvider) -> String? {
        switch provider {
        #if CloudSaaS
        case .claude:                     return "ClaudeBackend"
        case .openAI, .lmStudio, .custom: return "OpenAIBackend"
        case .openAIResponses:            return "OpenAIResponsesBackend"
        #endif
        #if Ollama
        case .ollama:                     return "OllamaBackend"
        #endif
        default: return nil
        }
    }

    // MARK: - Registration

    /// The default registrar fold. Order is significant only for
    /// `CloudBackends`, which calls `PinnedSessionDelegate.loadDefaultPins()`
    /// and must run before any URLSession factory. Local backends are
    /// independent.
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
    /// Each registrar is trait-gated internally, so a minimal build can register
    /// nothing — the returned count lets the caller fail fast on an empty,
    /// never-generating service instead of launching a dead app (the footgun
    /// audit's class D — "silent degradation where a fail-fast boundary check
    /// belongs"). ``ManifoldKit/ManifoldKit/quickStart(configuration:)`` does
    /// exactly this; hosts driving ``ManifoldBootstrap`` directly should check
    /// the result too.
    @MainActor
    @discardableResult
    public static func register(with service: InferenceService) -> Int {
        for registrar in registrars {
            registrar.register(with: service)
        }
        return service.registeredBackendSnapshot().count
    }
}
