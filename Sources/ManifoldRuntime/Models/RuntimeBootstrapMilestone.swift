/// Phases emitted during ``ManifoldRuntime`` bootstrap via
/// ``ManifoldRuntime/build(configuration:inferenceService:diagnostics:makeModelContainer:)``.
///
/// Consumers drive splash-screen or launch-progress UI by iterating the
/// `AsyncStream<RuntimeBootstrapMilestone>` returned alongside the in-flight
/// bootstrap `Task`. Each case is emitted exactly once, in the order declared,
/// before the stream finishes.
public enum RuntimeBootstrapMilestone: Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case installingConfiguration
    case resolvingInferenceService
    case buildingModelContainer
    case wiringPersistence
    case complete

    public var fractionComplete: Double {
        switch self {
        case .installingConfiguration: return 0.20
        case .resolvingInferenceService: return 0.40
        case .buildingModelContainer: return 0.70
        case .wiringPersistence: return 0.90
        case .complete: return 1.00
        }
    }

    public var description: String {
        switch self {
        case .installingConfiguration: return "Installing configuration"
        case .resolvingInferenceService: return "Resolving inference service"
        case .buildingModelContainer: return "Building model container"
        case .wiringPersistence: return "Wiring persistence"
        case .complete: return "Complete"
        }
    }
}
