import ManifoldInference

/// Registers the Ollama backend with an `InferenceService`.
///
/// Extracted from the umbrella's `CloudBackends` in the v0.48 product split
/// so the registration glue lives with the backend it constructs. The
/// umbrella's `CloudBackends.register` forwards here when the `Ollama`
/// trait is enabled, keeping `DefaultBackends.register` behaviour unchanged.
public enum OllamaBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        // Snapshot the service graph's own security policy (#2293) so the factory
        // closure scopes each backend to it rather than to process-global state.
        let securityPolicy = service.securityPolicy

        service.registerEndpointBackendFactory { provider in
            provider == .ollama
                ? OllamaBackend(_registrar: (), securityPolicy: securityPolicy)
                : nil
        }

        // Declare support via `availableInBuild` to stay coupled to
        // `CompiledBackends.current` — compile-time truth for what is in
        // this binary. Since v0.48 (traits retired) Ollama is always
        // compiled in, so this loop always declares `.ollama`; whether an
        // endpoint is *configured* is a runtime question the UI answers.
        for provider in APIProvider.availableInBuild where provider == .ollama {
            service.declareSupport(for: provider)
        }
    }
}
