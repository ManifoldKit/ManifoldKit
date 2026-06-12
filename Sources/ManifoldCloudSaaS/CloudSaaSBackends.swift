import ManifoldInference
import ManifoldCloudCore

/// Registers the SaaS provider backends (Claude, OpenAI Chat Completions,
/// OpenAI Responses, LM Studio / custom OpenAI-compatible endpoints) with
/// an `InferenceService`.
///
/// Extracted from the umbrella's `CloudBackends` in the v0.48 product split
/// so the registration glue lives with the backends it constructs. The
/// umbrella's `CloudBackends.register` forwards here when the `CloudSaaS`
/// trait is enabled, keeping `DefaultBackends.register` behaviour unchanged.
public enum CloudSaaSBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        PinnedSessionDelegate.loadDefaultPins()

        service.registerEndpointBackendFactory { provider in
            switch provider {
            case .claude:                     return ClaudeBackend()
            case .openAI, .lmStudio, .custom: return OpenAIBackend()
            case .openAIResponses:            return OpenAIResponsesBackend()
            default:                          return nil
            }
        }

        // Declare support via `availableInBuild` to stay coupled to
        // `CompiledBackends.current` — compile-time truth for what is in
        // this binary. Since v0.48 (traits retired) the SaaS providers are
        // always compiled in, so this loop always declares them; whether an
        // endpoint is *configured* is a runtime question the UI answers.
        for provider in APIProvider.availableInBuild where provider != .ollama {
            service.declareSupport(for: provider)
        }
    }
}
