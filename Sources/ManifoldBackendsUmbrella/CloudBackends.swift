import ManifoldInference
#if CloudSaaS || Ollama
import ManifoldCloudCore
import ManifoldCloud
#endif

public enum CloudBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        // Honour the BackendRegistrar contract: registration is a no-op when
        // every trait this registrar covers is disabled. Without this gate
        // we'd attach an always-nil factory and contradict the protocol
        // docstring.
        #if CloudSaaS || Ollama
        #if CloudSaaS
        PinnedSessionDelegate.loadDefaultPins()
        #endif

        service.registerEndpointBackendFactory { provider in
            switch provider {
            #if CloudSaaS
            case .claude:                     return ClaudeBackend()
            case .openAI, .lmStudio, .custom: return OpenAIBackend()
            case .openAIResponses:            return OpenAIResponsesBackend()
            #endif
            #if Ollama
            case .ollama:                     return OllamaBackend(_registrar: ())
            #endif
            default: return nil
            }
        }

        // Declare every provider this build can actually serve — depends on
        // which of `Ollama` / `CloudSaaS` traits is enabled.
        for provider in APIProvider.availableInBuild {
            service.declareSupport(for: provider)
        }
        #endif
    }
}
