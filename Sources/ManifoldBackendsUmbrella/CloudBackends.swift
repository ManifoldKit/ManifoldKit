import ManifoldInference
import ManifoldOllama
import ManifoldCloudSaaS

/// Cross-family forwarding registrar for the cloud backends.
///
/// The real registration glue moved next to the backends in the v0.48
/// product split (`OllamaBackends` in `ManifoldOllama`, `CloudSaaSBackends`
/// in `ManifoldCloudSaaS`); both families compile unconditionally now that
/// the Ollama / CloudSaaS traits are retired. This thin forwarder keeps the
/// `DefaultBackends.registrars` lineup unchanged for one release.
public enum CloudBackends: BackendRegistrar {
    @MainActor
    public static func register(with service: InferenceService) {
        OllamaBackends.register(with: service)
        CloudSaaSBackends.register(with: service)
    }
}
