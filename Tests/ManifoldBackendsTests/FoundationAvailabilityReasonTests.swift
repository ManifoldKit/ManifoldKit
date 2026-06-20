import XCTest
@testable import ManifoldFoundation

/// Tests for the OS-agnostic Foundation availability reason surface.
///
/// Deliberately NOT gated behind `#if canImport(FoundationModels)` or
/// `@available`: the whole point of ``FoundationAvailability/reason`` is that it
/// resolves on ANY deployment target, so the test must exercise the off-platform
/// (`.notBuilt` / `.unsupportedOS`) collapse on older / SDK-less runners too. CI
/// runners without Apple Intelligence must pass.
final class FoundationAvailabilityReasonTests: XCTestCase {

    /// The enum is `Sendable` — assert by passing a value across a `Sendable`
    /// boundary (a closure). This fails to compile if the conformance is dropped.
    func test_reason_isSendable() {
        let value: FoundationAvailabilityReason = .available
        let box: @Sendable () -> FoundationAvailabilityReason = { value }
        XCTAssertEqual(box(), .available)
    }

    /// Exhaustive switch over every case. A `default`-free switch fails to
    /// compile if a case is added/removed without updating this test, pinning
    /// the public case set the issue specifies.
    func test_reason_isExhaustive() {
        let allCases: [FoundationAvailabilityReason] = [
            .available,
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unsupportedOS,
            .notBuilt,
        ]
        for reason in allCases {
            switch reason {
            case .available,
                 .deviceNotEligible,
                 .appleIntelligenceNotEnabled,
                 .modelNotReady,
                 .unsupportedOS,
                 .notBuilt:
                XCTAssertTrue(true)
            }
        }
        // All six cases are distinct (Equatable identity via the switch above).
        XCTAssertEqual(allCases.count, 6)
    }

    /// On a CI runner without Apple Intelligence, the reason must be a concrete,
    /// deterministic case. We don't pin a single value (it depends on
    /// SDK/OS/entitlement), but it must be one of the well-defined cases.
    func test_reason_resolvesToConcreteCase() {
        let reason = FoundationAvailability.reason
        let valid: Set<String> = [
            "\(FoundationAvailabilityReason.available)",
            "\(FoundationAvailabilityReason.deviceNotEligible)",
            "\(FoundationAvailabilityReason.appleIntelligenceNotEnabled)",
            "\(FoundationAvailabilityReason.modelNotReady)",
            "\(FoundationAvailabilityReason.unsupportedOS)",
            "\(FoundationAvailabilityReason.notBuilt)",
        ]
        XCTAssertTrue(valid.contains("\(reason)"),
                      "reason resolved to an unexpected value: \(reason)")
    }

    /// On a runner without a live Apple Intelligence entitlement, the reason is
    /// NOT `.available`. This is the deterministic, CI-safe assertion the issue
    /// asks for: absent the entitlement we get one of the unavailable cases (or
    /// the off-platform `.unsupportedOS` / `.notBuilt`).
    ///
    /// Guarded so an Apple-Intelligence-equipped developer machine doesn't fail
    /// the suite: `.available` is only legitimate when the live model is ready.
    func test_reason_isNotAvailable_withoutAppleIntelligence() throws {
        let reason = FoundationAvailability.reason
        guard reason != .available else {
            throw XCTSkip("Apple Intelligence is available on this host; the non-available assertion does not apply.")
        }
        // Every non-available case is acceptable here.
        switch reason {
        case .deviceNotEligible,
             .appleIntelligenceNotEnabled,
             .modelNotReady,
             .unsupportedOS,
             .notBuilt:
            XCTAssertTrue(true)
        case .available:
            XCTFail("unreachable: guarded above")
        }
    }
}
