import ManifoldInference
import ManifoldFoundation

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
