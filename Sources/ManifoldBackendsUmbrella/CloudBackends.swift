import ManifoldInference
#if Ollama
import ManifoldOllama
#endif
#if CloudSaaS
import ManifoldCloudSaaS
#endif

/// Cross-family forwarding registrar for the cloud backends.
///
/// The real registration glue moved next to the backends in the v0.48
/// product split (`OllamaBackends` in `ManifoldOllama`, `CloudSaaSBackends`
/// in `ManifoldCloudSaaS`). This thin forwarder keeps the
/// `DefaultBackends.registrars` lineup — and the BackendRegistrar contract
/// that registration is a no-op when every trait this registrar covers is
/// disabled — unchanged for one release.
public enum CloudBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        #if Ollama
        OllamaBackends.register(with: service)
        #endif
        #if CloudSaaS
        CloudSaaSBackends.register(with: service)
        #endif
    }
}
