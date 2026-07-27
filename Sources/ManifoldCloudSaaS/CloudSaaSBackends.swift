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

        // Snapshot the service graph's own security policy (#2293), captured by
        // value so the factory closure — which runs later — reads this graph's
        // policy rather than process-global configuration.
        //
        // The scoped session is resolved **lazily on first backend construction**
        // and memoised, never eagerly here:
        // `URLSessionProvider.pinned(securityPolicy:)` `precondition`s on the
        // `networkDisabled` kill-switch, so building it at registration time would
        // crash a host that flips the kill-switch and then calls `quickStart()`.
        // Before #2293 that trap deferred to cloud-backend construction and never
        // fired in a process with no cloud endpoint; lazy resolution restores that.
        //
        // A `nil` policy keeps the pre-#2293 shape exactly: `urlSession: nil` lets
        // each backend resolve `URLSessionProvider.pinned` itself.
        let securityPolicy = service.securityPolicy
        let sessionBox = LazyPolicyScopedSession(securityPolicy: securityPolicy)

        service.registerEndpointBackendFactory { provider in
            let session = sessionBox.resolve()
            let backend: SSECloudBackend?
            switch provider {
            case .claude:                     backend = ClaudeBackend(urlSession: session)
            case .openAI, .lmStudio, .custom: backend = OpenAIBackend(urlSession: session)
            case .openAIResponses:            backend = OpenAIResponsesBackend(urlSession: session)
            default:                          backend = nil
            }
            backend?.securityPolicy = securityPolicy
            return backend
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
