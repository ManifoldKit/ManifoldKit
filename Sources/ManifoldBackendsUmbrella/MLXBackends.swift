import ManifoldInference
#if MLX
import ManifoldMLX
#endif

public enum MLXBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        #if MLX
        service.registerBackendFactory { modelType in
            switch modelType {
            case .mlx: return MLXBackend()
            default:   return nil
            }
        }
        service.declareSupport(for: .mlx)
        #endif
    }
}
