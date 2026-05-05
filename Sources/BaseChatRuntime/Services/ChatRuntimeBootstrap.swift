import BaseChatInference

/// Runtime-facing bootstrap contract consumed by UI view models.
///
/// Concrete bootstraps can live in persistence-specific targets while the UI
/// depends only on the runtime ports exposed here.
@MainActor
public protocol ChatRuntimeBootstrap: AnyObject {
    var persistenceStores: any SessionStore & MessageStore { get }
    var apiEndpointStore: any EndpointStore { get }
    var diagnosticsService: DiagnosticsService { get }
    var imageGenerationRuntime: ImageGenerationRuntime? { get }
}
