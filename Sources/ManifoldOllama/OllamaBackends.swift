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
        service.registerEndpointBackendFactory { provider in
            provider == .ollama ? OllamaBackend(_registrar: ()) : nil
        }

        // Declare support via `availableInBuild` (not unconditionally) to
        // preserve the pre-split coupling to `CompiledBackends.current`:
        // in a build whose trait set excludes Ollama, registration stays a
        // no-op on the declared-support side. The registration-derived
        // redesign of `CompiledBackends` is deliberately deferred (v0.48
        // plan, PR A4).
        for provider in APIProvider.availableInBuild where provider == .ollama {
            service.declareSupport(for: provider)
        }
    }
}
