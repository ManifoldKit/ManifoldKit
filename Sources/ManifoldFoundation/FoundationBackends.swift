import ManifoldInference

/// Registers the Apple Foundation Models backend with an `InferenceService`.
///
/// Relocated into `ManifoldFoundation` in P7 (was in the retired
/// `ManifoldBackends` umbrella). Pass it to
/// ``ManifoldKit/ManifoldKit/quickStart(backends:configuration:seed:)`` or call
/// `register(with:)` directly.
public enum FoundationBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        #if canImport(FoundationModels)
        service.registerBackendFactory { modelType in
            switch modelType {
            case .foundation:
                if #available(iOS 26, macOS 26, *) {
                    return FoundationBackend()
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        if #available(iOS 26, macOS 26, *) {
            service.declareSupport(for: .foundation)
        }
        #endif
    }
}
