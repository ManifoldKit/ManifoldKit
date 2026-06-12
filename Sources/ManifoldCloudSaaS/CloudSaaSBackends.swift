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

        // Declare support via `availableInBuild` (not unconditionally) to
        // preserve the pre-split coupling to `CompiledBackends.current`:
        // in a build whose trait set excludes CloudSaaS, registration stays
        // a no-op on the declared-support side. The registration-derived
        // redesign of `CompiledBackends` is deliberately deferred (v0.48
        // plan, PR A4).
        for provider in APIProvider.availableInBuild where provider != .ollama {
            service.declareSupport(for: provider)
        }
    }
}
