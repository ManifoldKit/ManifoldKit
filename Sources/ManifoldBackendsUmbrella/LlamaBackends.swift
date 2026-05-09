import ManifoldInference
#if Llama
import ManifoldLlama
#endif

public enum LlamaBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        #if Llama
        service.registerBackendFactory { modelType in
            switch modelType {
            case .gguf: return LlamaBackend()
            default:    return nil
            }
        }
        service.declareSupport(for: .gguf)
        #endif
    }
}
