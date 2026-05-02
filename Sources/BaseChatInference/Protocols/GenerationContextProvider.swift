/// Provides the generation coordinator with read access to the currently loaded
/// backend, model-loaded state, and prompt template.
///
/// `InferenceService` conforms to this protocol so the `GenerationQueue`
/// can operate without a direct dependency on `ModelLifecycleCoordinator`.
@MainActor
protocol GenerationContextProvider: AnyObject {
    var currentBackend: (any InferenceBackend)? { get }
    var isBackendLoaded: Bool { get }
    var selectedPromptTemplate: PromptTemplate { get }
}
