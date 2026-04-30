/// Phases emitted during ``BaseChatRuntime`` bootstrap via
/// ``BaseChatRuntime/build(configuration:inferenceService:diagnostics:makeModelContainer:)``.
///
/// Consumers drive splash-screen or launch-progress UI by iterating the
/// `AsyncStream<RuntimeBootstrapMilestone>` returned alongside the in-flight
/// bootstrap `Task`. Each case is emitted exactly once, in the order declared,
/// before the stream finishes.
public enum RuntimeBootstrapMilestone: Sendable, Hashable, CaseIterable, CustomStringConvertible {

    /// ``BaseChatConfiguration/shared`` is about to be set to the supplied
    /// configuration. This is the first milestone yielded.
    case installingConfiguration

    /// The ``InferenceService`` instance (injected or newly created) is ready.
    case resolvingInferenceService

    /// The `ModelContainer` has been built and its schema migration (if any)
    /// has completed.
    case buildingModelContainer

    /// The `SwiftData`-backed persistence providers are wired to the container's
    /// `mainContext`.
    case wiringPersistence

    /// Bootstrap completed successfully. The ``BaseChatRuntime`` instance is
    /// available via the returned `Task`'s value.
    case complete

    // MARK: - Progress helpers

    /// Fraction of bootstrap work completed at this milestone, in `0.0 ... 1.0`.
    ///
    /// Suitable for feeding directly into a `ProgressView(value:)` or a custom
    /// progress bar on a splash screen.
    public var fractionComplete: Double {
        switch self {
        case .installingConfiguration:  return 0.20
        case .resolvingInferenceService: return 0.40
        case .buildingModelContainer:   return 0.70
        case .wiringPersistence:        return 0.90
        case .complete:                 return 1.00
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .installingConfiguration:  return "Installing configuration"
        case .resolvingInferenceService: return "Resolving inference service"
        case .buildingModelContainer:   return "Building model container"
        case .wiringPersistence:        return "Wiring persistence"
        case .complete:                 return "Complete"
        }
    }
}
