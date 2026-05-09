/// A unit of backend registration that can be folded over to bootstrap an
/// `InferenceService`. Conforming types own a single backend family
/// (MLX, Llama, Foundation, Cloud) and register their factories and
/// supported model types on the supplied service.
///
/// `register(with:)` must be a no-op when its trait is disabled — never a
/// missing-symbol link error. Trait gates live inside the function body,
/// not at file scope, so consumers can call any registrar regardless of
/// build configuration.
public protocol BackendRegistrar {
    @MainActor static func register(with service: InferenceService)
}
