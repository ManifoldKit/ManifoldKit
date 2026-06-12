import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldCloudCore

// MARK: - Pure Routing Tests (no hardware required)

/// Tests the pure routing functions in DefaultBackends.
/// These run in CI — no hardware, no backend instantiation.
final class DefaultBackendsRoutingTests: XCTestCase {

    func test_routing_gguf_returnsNilPostSplit() {
        // LlamaBackend lives in the manifold-llama companion package since
        // v0.48 (PR C2) — core routing must never claim it.
        XCTAssertNil(DefaultBackends.backendTypeName(for: .gguf))
    }

    func test_routing_mlx_returnsNilPostSplit() {
        // MLXBackend lives in the manifold-mlx companion package since
        // v0.48 (PR C2) — core routing must never claim it.
        XCTAssertNil(DefaultBackends.backendTypeName(for: .mlx))
    }

    func test_routing_foundation_mapsToFoundationBackend() {
        #if canImport(FoundationModels)
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .foundation), "FoundationBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .foundation))
        #endif
    }

    func test_routing_openAI_mapsToOpenAIBackend() {
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .openAI), "OpenAIBackend")
    }

    func test_routing_claude_mapsToClaudeBackend() {
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .claude), "ClaudeBackend")
    }

    func test_routing_ollama_mapsToOllamaBackend() {
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .ollama), "OllamaBackend")
    }

    func test_routing_lmStudio_mapsToOpenAIBackend() {
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .lmStudio), "OpenAIBackend")
    }

    func test_routing_custom_mapsToOpenAIBackend() {
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .custom), "OpenAIBackend")
    }
}

// MARK: - Integration Tests (require hardware)

/// Tests that DefaultBackends registration completes without error.
/// Hardware-free since v0.48 (PR C2): the fold is Foundation + Cloud only;
/// the LlamaBackend/MLXBackend paths live in the companion packages.
@MainActor
final class DefaultBackendsTests: XCTestCase {

    func test_register_doesNotCrash() {
        let service = InferenceService()
        DefaultBackends._register(with: service)
        // If we get here, registration succeeded
    }

    func test_register_canBeCalledMultipleTimes() {
        let service = InferenceService()
        DefaultBackends._register(with: service)
        DefaultBackends._register(with: service)
        // Should not crash or corrupt state
    }
}

// MARK: - Registrar Tests (no hardware required)

/// Asserts that each per-backend registrar declares the right `ModelType` /
/// `APIProvider` support, and that `DefaultBackends._register(with:)` is
/// equivalent to invoking the surviving registrars (Cloud + Foundation)
/// explicitly. The MLX / Llama registrars moved to the companion packages
/// (v0.48, PR C2) — their declaration tests moved with them.
///
/// Runs without hardware: factory closures are appended but never executed,
/// so `registeredBackendSnapshot()` only reflects `declareSupport` calls.
///
/// ## Sabotage-verify spec
///
/// To confirm these tests actually catch drift, temporarily edit the production
/// code as below and re-run — each edit must produce a failure:
///
/// 1. **Drop a cloud declareSupport.** In `OllamaBackends.swift` /
///    `CloudSaaSBackends.swift` comment out the
///    `for provider in APIProvider.availableInBuild { ... }` loop.
///    `test_cloudRegistrar_declaresAvailableProviders` must fail in any
///    build shape (cloud always compiles since v0.48).
/// 2. **Drop a registrar from the fold.** In `DefaultBackends.swift` remove
///    `CloudBackends.self` from `_registrars` —
///    `test_defaultRegister_equalsExplicitFold` must fail on `cloudProviders`
///    mismatch.
///
/// Restore each edit before committing.
@MainActor
final class DefaultBackendsRegistrarTests: XCTestCase {

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

    func test_cloudRegistrar_declaresAvailableProviders() {
        let service = InferenceService()
        CloudBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()
        XCTAssertEqual(snapshot.cloudProviders, Set(APIProvider.availableInBuild),
                       "CloudBackends.register must declare every provider in APIProvider.availableInBuild")
    }

    // MARK: - Equivalence

    func test_defaultRegister_equalsExplicitFold() {
        let viaFacade = InferenceService()
        DefaultBackends._register(with: viaFacade)

        let viaExplicit = InferenceService()
        // Explicit list — independent of `DefaultBackends._registrars` so a
        // drop from that list surfaces here as a snapshot mismatch.
        CloudBackends.register(with: viaExplicit)
        FoundationBackends.register(with: viaExplicit)

        XCTAssertEqual(
            viaFacade.registeredBackendSnapshot(),
            viaExplicit.registeredBackendSnapshot(),
            "DefaultBackends.register must match an explicit fold over the surviving BackendRegistrars (Cloud + Foundation)."
        )
    }

    func test_cloudAndFoundationRegistrars_declareDisjointSurfaces() {
        let cloudService = InferenceService()
        CloudBackends.register(with: cloudService)

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

/// Verifies `CloudBackends.register(with:)` loads default certificate pins
/// before any URLSession factory could be exercised. The `_defaultPinsLoaded`
/// guard makes `loadDefaultPins()` idempotent across multiple calls but the
/// **first** call must originate from the registrar — not from the lazy
/// initializer of `URLSessionProvider._pinned`. If a future refactor moves
/// the call out of `CloudBackends.register`, this asserts surfaces it.
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
        CloudBackends.register(with: service)

        // At-least-2 instead of exactly-2: pin rotation procedures legitimately
        // add backup pins (temporarily during a swap, or permanently). The
        // invariant we're asserting is "the registrar populated pins for these
        // hosts before any URLSession could fire", not the bundled pin count.
        XCTAssertGreaterThanOrEqual(PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]?.count ?? 0, 2,
                                    "CloudBackends.register must populate Anthropic pins (at minimum: intermediate + root)")
        XCTAssertGreaterThanOrEqual(PinnedSessionDelegate.pinnedHosts["api.openai.com"]?.count ?? 0, 2,
                                    "CloudBackends.register must populate OpenAI pins (at minimum: intermediate + root)")
    }
}
