#if canImport(FoundationModels)
import FoundationModels

/// Abstracts `SystemLanguageModel.default.availability` so unit tests can inject
/// a stubbed answer without requiring a real Apple Intelligence entitlement.
///
/// The production implementation (`SystemAvailabilityProvider`) forwards directly
/// to `SystemLanguageModel.default.availability`. Tests inject
/// `StubAvailabilityProvider` to drive the unavailable branch in `loadModel`.
@available(iOS 26, macOS 26, *)
protocol FoundationModelAvailabilityProvider: Sendable {
    var availability: SystemLanguageModel.Availability { get }
}

/// Production implementation — forwards to the real system model.
@available(iOS 26, macOS 26, *)
struct SystemAvailabilityProvider: FoundationModelAvailabilityProvider {
    static let shared = SystemAvailabilityProvider()
    var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }
}

#endif
