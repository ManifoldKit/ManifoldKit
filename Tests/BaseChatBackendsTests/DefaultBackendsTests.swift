import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatCloudCore

// MARK: - Pure Routing Tests (no hardware required)

/// Tests the pure routing functions in DefaultBackends.
/// These run in CI — no hardware, no backend instantiation.
final class DefaultBackendsRoutingTests: XCTestCase {

    func test_routing_gguf_mapsToLlamaBackend() {
        #if Llama
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .gguf), "LlamaBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .gguf))
        #endif
    }

    func test_routing_mlx_mapsToMLXBackend() {
        #if MLX
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .mlx), "MLXBackend")
        #else
        // MLX trait not enabled in this build — routing returns nil, which is correct.
        XCTAssertNil(DefaultBackends.backendTypeName(for: .mlx))
        #endif
    }

    func test_routing_foundation_mapsToFoundationBackend() {
        #if canImport(FoundationModels)
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .foundation), "FoundationBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .foundation))
        #endif
    }

    func test_routing_openAI_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .openAI), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .openAI))
        #endif
    }

    func test_routing_claude_mapsToClaudeBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .claude), "ClaudeBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .claude))
        #endif
    }

    func test_routing_ollama_mapsToOllamaBackend() {
        #if Ollama
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .ollama), "OllamaBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .ollama))
        #endif
    }

    func test_routing_lmStudio_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .lmStudio), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .lmStudio))
        #endif
    }

    func test_routing_custom_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .custom), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .custom))
        #endif
    }
}

// MARK: - Integration Tests (require hardware)

/// Tests that DefaultBackends.register completes without error and
/// that the resulting InferenceService can attempt model loads
/// (which exercises the factory lookup path).
///
/// Registration creates LlamaBackend instances, which require Apple Silicon.
@MainActor
final class DefaultBackendsTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "DefaultBackends registers LlamaBackend which requires Metal")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "DefaultBackends registers LlamaBackend which requires Apple Silicon")
    }

    func test_register_doesNotCrash() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        // If we get here, registration succeeded
    }

    func test_register_canBeCalledMultipleTimes() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        DefaultBackends.register(with: service)
        // Should not crash or corrupt state
    }

    #if Llama
    func test_loadModel_gguf_invalidPath_throwsModelLoadFailed() async {
        let service = InferenceService()
        DefaultBackends.register(with: service)

        let fakeModel = ModelInfo(
            name: "test",
            fileName: "nonexistent.gguf",
            url: URL(fileURLWithPath: "/tmp/nonexistent.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: fakeModel, plan: .testStub(effectiveContextSize: 2048))
            XCTFail("Should throw for nonexistent GGUF file")
        } catch {
            // Expected — the factory created a LlamaBackend which failed to load
            XCTAssertFalse(service.isModelLoaded)
        }
    }
    #endif

    // Note: MLX backend tests require Xcode's Metal toolchain and cannot
    // run under `swift test`. Test MLX through the Xcode scheme instead.
}

// MARK: - Registrar Tests (no hardware required)

/// Asserts that each per-backend registrar declares the right `ModelType` /
/// `APIProvider` support, and that `DefaultBackends.register(with:)` is
/// equivalent to invoking the four registrars explicitly.
///
/// Runs without hardware: factory closures are appended but never executed,
/// so `registeredBackendSnapshot()` only reflects `declareSupport` calls.
///
/// ## Sabotage-verify spec
///
/// To confirm these tests actually catch drift, temporarily edit the production
/// code as below and re-run — each edit must produce a failure:
///
/// 1. **Drop a local declareSupport.** In `MLXBackends.swift` comment out
///    `service.declareSupport(for: .mlx)`. With `--traits MLX`,
///    `test_mlxRegistrar_declaresMLX` must fail.
/// 2. **Drop a cloud declareSupport.** In `CloudBackends.swift` comment out
///    the `for provider in APIProvider.availableInBuild { ... }` loop. With
///    `--traits CloudSaaS` or `--traits Ollama`,
///    `test_cloudRegistrar_declaresAvailableProviders` must fail.
/// 3. **Drop a registrar from the fold.** In `DefaultBackends.swift` remove
///    `LlamaBackends.self` from `registrars`. With `--traits Llama`,
///    `test_defaultRegister_equalsExplicitFold` must fail on `localModelTypes`
///    mismatch.
///
/// Restore each edit before committing.
@MainActor
final class DefaultBackendsRegistrarTests: XCTestCase {

    // MARK: - Per-registrar declarations

    func test_mlxRegistrar_declaresMLX() {
        let service = InferenceService()
        MLXBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()
        #if MLX
        XCTAssertTrue(snapshot.localModelTypes.contains(.mlx),
                      "MLXBackends.register must declareSupport(for: .mlx) when MLX trait is enabled")
        #else
        XCTAssertFalse(snapshot.localModelTypes.contains(.mlx),
                       "MLXBackends.register must be a no-op when MLX trait is disabled")
        #endif
    }

    func test_llamaRegistrar_declaresGGUF() {
        let service = InferenceService()
        LlamaBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()
        #if Llama
        XCTAssertTrue(snapshot.localModelTypes.contains(.gguf),
                      "LlamaBackends.register must declareSupport(for: .gguf) when Llama trait is enabled")
        #else
        XCTAssertFalse(snapshot.localModelTypes.contains(.gguf),
                       "LlamaBackends.register must be a no-op when Llama trait is disabled")
        #endif
    }

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
        DefaultBackends.register(with: viaFacade)

        let viaExplicit = InferenceService()
        // Explicit list — independent of `DefaultBackends.registrars` so a
        // drop from that list surfaces here as a snapshot mismatch.
        CloudBackends.register(with: viaExplicit)
        MLXBackends.register(with: viaExplicit)
        LlamaBackends.register(with: viaExplicit)
        FoundationBackends.register(with: viaExplicit)

        XCTAssertEqual(
            viaFacade.registeredBackendSnapshot(),
            viaExplicit.registeredBackendSnapshot(),
            "DefaultBackends.register must match an explicit fold over all four BackendRegistrars."
        )
    }

    func test_localRegistrars_declareDisjointModelTypes() {
        let mlxService = InferenceService()
        MLXBackends.register(with: mlxService)

        let llamaService = InferenceService()
        LlamaBackends.register(with: llamaService)

        let foundationService = InferenceService()
        FoundationBackends.register(with: foundationService)

        let mlx = mlxService.registeredBackendSnapshot().localModelTypes
        let llama = llamaService.registeredBackendSnapshot().localModelTypes
        let foundation = foundationService.registeredBackendSnapshot().localModelTypes

        XCTAssertTrue(mlx.intersection(llama).isEmpty,
                      "MLX and Llama registrars must declare disjoint model types — overlap: \(mlx.intersection(llama))")
        XCTAssertTrue(mlx.intersection(foundation).isEmpty,
                      "MLX and Foundation registrars must declare disjoint model types — overlap: \(mlx.intersection(foundation))")
        XCTAssertTrue(llama.intersection(foundation).isEmpty,
                      "Llama and Foundation registrars must declare disjoint model types — overlap: \(llama.intersection(foundation))")
    }
}

// MARK: - Cloud Pin Loading (CloudSaaS only)

#if CloudSaaS
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
#endif
