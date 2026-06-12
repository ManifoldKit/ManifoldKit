import XCTest
@testable import ManifoldInference

final class CompiledBackendsTests: XCTestCase {

    // MARK: - Profile mapping (trait-set → build profile)
    //
    // `buildProfile(for:)` is a pure function over hand-constructed trait
    // sets, so every combination stays testable even though
    // `CompiledBackends.current` always carries both cloud members since
    // v0.48. Sabotaging `CompiledBackends.buildProfile(for:)` breaks these.

    func test_buildProfile_offline_whenNoNetworkTraits() {
        XCTAssertEqual(CompiledBackends.buildProfile(for: []), .offline)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.mlx]), .offline)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.llama]), .offline)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.mlx, .llama]), .offline)
    }

    func test_buildProfile_selfHosted_whenOnlyOllama() {
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.ollama]), .selfHosted)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.mlx, .ollama]), .selfHosted)
    }

    func test_buildProfile_saas_whenOnlyCloudSaaS() {
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.cloudSaaS]), .saas)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.llama, .cloudSaaS]), .saas)
    }

    func test_buildProfile_full_whenBothNetworkTraits() {
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.ollama, .cloudSaaS]), .full)
        XCTAssertEqual(CompiledBackends.buildProfile(for: [.mlx, .llama, .ollama, .cloudSaaS]), .full)
    }

    // MARK: - Concrete shape under the current build configuration

    // Since v0.48 (PR A4) the cloud families compile unconditionally, and
    // since PR C2 the MLX / Llama families are NEVER compiled into core —
    // they live in the manifold-mlx / manifold-llama companion packages and
    // are only visible at runtime via InferenceService registration.
    // Foundation Models remain conditionally available based on the host OS.

    func test_current_alwaysIncludesCloudFamilies() {
        let compiled = CompiledBackends.current

        XCTAssertTrue(compiled.traits.contains(.ollama),
            "Ollama is always compiled in since v0.48 — its trait is retired")
        XCTAssertTrue(compiled.traits.contains(.cloudSaaS),
            "CloudSaaS is always compiled in since v0.48 — its trait is retired")
        XCTAssertEqual(compiled.buildProfile, .full,
            "With both cloud families constant, the current profile is always .full")
        XCTAssertTrue(compiled.supportsCloudInference)
        XCTAssertTrue(compiled.shouldPresentCloudAPIManagement,
            "Cloud API management UI is always presentable; endpoint configuration is the runtime gate")
    }

    func test_current_neverIncludesCompanionFamilies() {
        let compiled = CompiledBackends.current

        // The MLX / Llama families moved to companion packages (v0.48, PR
        // C2, #1749). Compile-time reflection must never claim them; runtime
        // registration (InferenceService.registeredBackendSnapshot()) is the
        // only honest source for companion-provided capability.
        XCTAssertFalse(compiled.traits.contains(.llama),
            "Core never compiles the Llama family — it lives in manifold-llama")
        XCTAssertFalse(compiled.traits.contains(.mlx),
            "Core never compiles the MLX family — it lives in manifold-mlx")
        XCTAssertFalse(compiled.localModelTypes.contains(.gguf),
            "GGUF must not appear in compile-time localModelTypes post-split")
        XCTAssertFalse(compiled.localModelTypes.contains(.mlx),
            "MLX must not appear in compile-time localModelTypes post-split")
    }

    func test_current_alwaysIncludesHuggingFace() {
        XCTAssertTrue(CompiledBackends.current.traits.contains(.huggingFace),
            "HuggingFace download machinery is always compiled in since v0.48 (PR C2)")
    }

    func test_current_cloudBuild_includesClaudeAndOpenAI() {
        let compiled = CompiledBackends.current

        XCTAssertTrue(compiled.cloudProviders.contains(.claude))
        XCTAssertTrue(compiled.cloudProviders.contains(.openAI))
        XCTAssertTrue(compiled.cloudProviders.contains(.openAIResponses))
        XCTAssertTrue(compiled.cloudProviders.contains(.lmStudio))
        XCTAssertTrue(compiled.cloudProviders.contains(.custom))
    }

    func test_current_ollamaBuild_includesOllamaProvider() {
        XCTAssertTrue(CompiledBackends.current.cloudProviders.contains(.ollama))
    }

    // MARK: - Cross-cutting invariants

    func test_downloadableModelTypes_areSubsetOfLocalModelTypes() {
        let compiled = CompiledBackends.current

        XCTAssertTrue(compiled.downloadableModelTypes.isSubset(of: compiled.localModelTypes))
        XCTAssertTrue(compiled.downloadableModelTypes.isSubset(of: [.gguf, .mlx]))
        XCTAssertFalse(compiled.downloadableModelTypes.contains(.foundation),
            "Foundation Models are not downloadable; they ship with the OS")
    }

    func test_presentationFlags_followCompiledSets() {
        let compiled = CompiledBackends.current

        XCTAssertEqual(
            compiled.shouldPresentModelDownloads,
            compiled.traits.contains(.huggingFace) && !compiled.downloadableModelTypes.isEmpty
        )
        XCTAssertEqual(compiled.shouldPresentCloudAPIManagement, !compiled.cloudProviders.isEmpty)
    }

    func test_modelCompatibility_matchesCompiledLocalTypes() {
        let compiled = CompiledBackends.current

        for modelType in [ModelType.gguf, .mlx, .foundation] {
            let expected = compiled.localModelTypes.contains(modelType)
            XCTAssertEqual(compiled.compatibility(for: modelType).isSupported, expected)
        }
    }

    func test_providerCompatibility_matchesCompiledProviders() {
        let compiled = CompiledBackends.current

        for provider in APIProvider.allCases {
            let expected = compiled.cloudProviders.contains(provider)
            XCTAssertEqual(compiled.compatibility(for: provider).isSupported, expected)
        }
    }

    func test_apiProvider_availableInBuild_matchesCompiledBackends() {
        XCTAssertEqual(APIProvider.availableInBuild, CompiledBackends.current.orderedCloudProviders)
    }

    func test_orderedCloudProviders_preservesDocumentedOrder() {
        // Sabotage check: re-shuffling the filter chain in
        // `orderedCloudProviders` must trip this assertion.
        let allProviders: Set<APIProvider> = Set(APIProvider.allCases)
        let compiled = CompiledBackends(
            buildProfile: .full,
            traits: [.ollama, .cloudSaaS],
            localModelTypes: [],
            cloudProviders: allProviders
        )

        XCTAssertEqual(
            compiled.orderedCloudProviders,
            [.claude, .openAI, .openAIResponses, .lmStudio, .custom, .ollama]
        )
    }

    @MainActor
    func test_frameworkCapabilityService_exposesCompiledBackends() {
        let service = FrameworkCapabilityService(inferenceService: InferenceService())

        XCTAssertEqual(service.compiledBackends, .current)
    }
}
