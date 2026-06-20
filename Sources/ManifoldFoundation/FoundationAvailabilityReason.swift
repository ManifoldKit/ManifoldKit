// Deliberately NOT wrapped in `#if canImport(FoundationModels)`: the whole
// point of this surface is to give hosts a structured availability reason that
// resolves on ANY deployment target — including ones where FoundationModels is
// not importable (`.notBuilt`) or the OS is too old (`.unsupportedOS`) — without
// the host importing the Apple SDK or writing `#available` guards. If this file
// were gated like `FoundationBackend.swift`, the off-platform cases could never
// be reached.

/// OS-agnostic reason describing why Apple Foundation (on-device Apple
/// Intelligence) is or isn't available, suitable for driving host UI.
///
/// Mirrors Apple's `SystemLanguageModel.Availability.UnavailableReason`
/// internally, but collapses off-platform situations to ``unsupportedOS`` /
/// ``notBuilt`` so callers on any deployment target get a structured value
/// without importing `FoundationModels`.
public enum FoundationAvailabilityReason: Sendable {
    /// The on-device model is available and ready to serve inference.
    case available
    /// The device hardware does not support Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is supported but not enabled in System Settings.
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is enabled but the model is still downloading / warming.
    case modelNotReady
    /// The running OS predates iOS 26 / macOS 26, so the API is unavailable.
    case unsupportedOS
    /// The build was compiled without the FoundationModels framework
    /// (`!canImport(FoundationModels)`), so the backend is not present.
    case notBuilt
}

/// OS-agnostic entry point for reading Foundation availability.
///
/// Hosts call ``FoundationAvailability/reason`` (or the convenience
/// ``FoundationBackend/availabilityReason`` static) instead of importing
/// `FoundationModels` and `#available`-gating the read of
/// `SystemLanguageModel.default.availability` themselves.
public enum FoundationAvailability {
    /// The current structured availability reason on this device + build.
    ///
    /// Resolves to ``FoundationAvailabilityReason/notBuilt`` when the
    /// FoundationModels framework isn't importable, ``FoundationAvailabilityReason/unsupportedOS``
    /// when the OS predates iOS 26 / macOS 26, and otherwise maps Apple's
    /// `SystemLanguageModel.Availability` (including its non-frozen
    /// `UnavailableReason`) to a stable case.
    public static var reason: FoundationAvailabilityReason {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return mapAppleAvailability(SystemLanguageModel.default.availability)
        } else {
            return .unsupportedOS
        }
        #else
        return .notBuilt
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, macOS 26, *)
extension FoundationAvailability {
    /// Maps Apple's non-frozen availability enum onto our stable reason.
    ///
    /// Factored out (and `@available`-gated) so the OS-agnostic ``reason``
    /// accessor above stays free of the Apple types. `@unknown default` is
    /// mandatory: `UnavailableReason` is non-frozen and Apple may add cases.
    static func mapAppleAvailability(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationAvailabilityReason {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                // A new Apple-side reason we don't model yet. Surfacing
                // `.modelNotReady` (a transient, retry-shaped state) is the
                // least-wrong default for a "not available, reason unknown"
                // situation versus the terminal `.deviceNotEligible`.
                return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
    }
}
#endif
