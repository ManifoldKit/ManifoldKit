import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

// The `DefaultBackends` / `CloudBackends` umbrella registrars were retired in
// P7 (the 1.0 shim clean-up). The compiled-in default fold is now the explicit
// list of surviving family registrars: `OllamaBackends`, `CloudSaaSBackends`,
// and `FoundationBackends`. These tests pin the registration behaviour of that
// fold directly against the family registrars.

// MARK: - Default fold registration

/// The compiled-in default registrars (Ollama + SaaS + Foundation) register
/// without crashing and are idempotent. Hardware-free: factory closures are
/// appended but never executed.
@MainActor
final class DefaultBackendsTests: XCTestCase {

    /// Mirrors `ManifoldKit.defaultBackendRegistrars` without taking a
    /// dependency on the ManifoldKit umbrella from this backend-family suite.
    private let defaultRegistrars: [any BackendRegistrar.Type] = [
        OllamaBackends.self,
        CloudSaaSBackends.self,
        FoundationBackends.self,
    ]

    private func registerDefaults(with service: InferenceService) {
        for registrar in defaultRegistrars {
            registrar.register(with: service)
        }
    }

    func test_register_doesNotCrash() {
        let service = InferenceService()
        registerDefaults(with: service)
        // If we get here, registration succeeded.
    }

    func test_register_canBeCalledMultipleTimes() {
        let service = InferenceService()
        registerDefaults(with: service)
        registerDefaults(with: service)
        // Should not crash or corrupt state.
    }
}

// MARK: - Registrar declarations

/// Asserts that each surviving per-family registrar declares the right
/// `ModelType` / `APIProvider` support, and that the default fold equals an
/// explicit fold over the same registrars.
///
/// ## Sabotage-verify spec
///
/// 1. **Drop a cloud declareSupport.** In `OllamaBackends.swift` /
///    `CloudSaaSBackends.swift` comment out the provider-declaration loop.
///    `test_cloudRegistrars_declareAvailableProviders` must fail.
/// 2. **Drop a registrar from the default fold.** Remove `OllamaBackends.self`
///    from `defaultRegistrars` above — `test_defaultFold_equalsExplicitFold`
///    must fail on `cloudProviders` mismatch.
///
/// Restore each edit before committing.
@MainActor
final class DefaultBackendsRegistrarTests: XCTestCase {

    private let defaultRegistrars: [any BackendRegistrar.Type] = [
        OllamaBackends.self,
        CloudSaaSBackends.self,
        FoundationBackends.self,
    ]

    private func registerDefaults(with service: InferenceService) {
        for registrar in defaultRegistrars {
            registrar.register(with: service)
        }
    }

    // MARK: - Per-registrar declarations

    func test_foundationRegistrar_declaresFoundationWhenAvailable() {
        let service = InferenceService()
        FoundationBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            XCTAssertTrue(snapshot.localModelTypes.contains(.foundation),
                          "FoundationBackends.register must declareSupport(for: .foundation) on supported OS versions")
        } else {
            XCTAssertFalse(snapshot.localModelTypes.contains(.foundation),
                           "FoundationBackends.register must skip declareSupport on unsupported OS versions")
        }
        #else
        XCTAssertFalse(snapshot.localModelTypes.contains(.foundation),
                       "FoundationBackends.register must be a no-op without FoundationModels SDK")
        #endif
    }

    func test_cloudRegistrars_declareAvailableProviders() {
        let service = InferenceService()
        OllamaBackends.register(with: service)
        CloudSaaSBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()
        XCTAssertEqual(snapshot.cloudProviders, Set(APIProvider.availableInBuild),
                       "The cloud registrars must declare every provider in APIProvider.availableInBuild")
    }

    // MARK: - Equivalence

    func test_defaultFold_equalsExplicitFold() {
        let viaFold = InferenceService()
        registerDefaults(with: viaFold)

        let viaExplicit = InferenceService()
        // Explicit list — independent of `defaultRegistrars` so a drop from
        // that list surfaces here as a snapshot mismatch.
        OllamaBackends.register(with: viaExplicit)
        CloudSaaSBackends.register(with: viaExplicit)
        FoundationBackends.register(with: viaExplicit)

        XCTAssertEqual(
            viaFold.registeredBackendSnapshot(),
            viaExplicit.registeredBackendSnapshot(),
            "The default fold must match an explicit fold over the surviving BackendRegistrars (Ollama + SaaS + Foundation)."
        )
    }

    func test_cloudAndFoundationRegistrars_declareDisjointSurfaces() {
        let cloudService = InferenceService()
        OllamaBackends.register(with: cloudService)
        CloudSaaSBackends.register(with: cloudService)

        let foundationService = InferenceService()
        FoundationBackends.register(with: foundationService)

        let cloudLocal = cloudService.registeredBackendSnapshot().localModelTypes
        let foundation = foundationService.registeredBackendSnapshot().localModelTypes

        XCTAssertTrue(cloudLocal.isEmpty,
                      "Cloud registrars must not declare local model types — got: \(cloudLocal)")
        XCTAssertTrue(foundationService.registeredBackendSnapshot().cloudProviders.isEmpty,
                      "Foundation registrar must not declare cloud providers")
        XCTAssertTrue(cloudLocal.intersection(foundation).isEmpty)
    }
}

// MARK: - Cloud Pin Loading (CloudSaaS only)

/// Verifies the cloud registrar loads default certificate pins before any
/// URLSession factory could be exercised. The `_defaultPinsLoaded` guard makes
/// `loadDefaultPins()` idempotent across multiple calls but the **first** call
/// must originate from the registrar — not from the lazy initializer of
/// `URLSessionProvider._pinned`.
@MainActor
final class CloudBackendsPinLoadingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        // Clear any pins set by a prior test in the same process.
        for host in ["api.anthropic.com", "api.openai.com"] {
            PinnedSessionDelegate.pinnedHosts[host] = nil
        }
    }

    func test_register_populatesDefaultPinsForKnownHosts() {
        XCTAssertNil(PinnedSessionDelegate.pinnedHosts["api.anthropic.com"],
                     "Pre-condition: pins must be cleared")
        XCTAssertNil(PinnedSessionDelegate.pinnedHosts["api.openai.com"],
                     "Pre-condition: pins must be cleared")

        let service = InferenceService()
        CloudSaaSBackends.register(with: service)

        // At-least-2 instead of exactly-2: pin rotation procedures legitimately
        // add backup pins. The invariant we're asserting is "the registrar
        // populated pins for these hosts before any URLSession could fire", not
        // the bundled pin count.
        XCTAssertGreaterThanOrEqual(PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]?.count ?? 0, 2,
                                    "CloudSaaSBackends.register must populate Anthropic pins (at minimum: intermediate + root)")
        XCTAssertGreaterThanOrEqual(PinnedSessionDelegate.pinnedHosts["api.openai.com"]?.count ?? 0, 2,
                                    "CloudSaaSBackends.register must populate OpenAI pins (at minimum: intermediate + root)")
    }
}
