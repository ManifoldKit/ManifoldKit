import BaseChatInference
#if MLX
import BaseChatMLX
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
