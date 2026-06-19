import ManifoldInference

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
    var videoGenerationRuntime: VideoGenerationRuntime? { get }
    var audioGenerationRuntime: AudioGenerationRuntime? { get }
    var webSearchRuntimePort: (any WebSearchRuntime)? { get }
}

public extension ChatRuntimeBootstrap {
    /// Audio generation is opt-in; bootstraps that don't wire a TTS runtime
    /// inherit this `nil` default so existing conformers stay source-compatible.
    var audioGenerationRuntime: AudioGenerationRuntime? { nil }
}
