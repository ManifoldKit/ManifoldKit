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

    // Since v0.48 (PR A4) the cloud families compile unconditionally, so
    // `CompiledBackends.current` always reports the full cloud surface in
    // every lane, including `--disable-default-traits`. Only MLX / Llama /
    // HuggingFace remain build-dependent until the companion split (C2).
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

    func test_current_localModelTypes_trackHardwareTraits() {
        let compiled = CompiledBackends.current

        // GGUF support requires the Llama trait.
        if !compiled.traits.contains(.llama) {
            XCTAssertFalse(compiled.localModelTypes.contains(.gguf),
                "GGUF must not be compiled in without the Llama trait")
        }

        // MLX support requires the MLX trait.
        if !compiled.traits.contains(.mlx) {
            XCTAssertFalse(compiled.localModelTypes.contains(.mlx),
                "MLX must not be compiled in without the MLX trait")
        }
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

    #if Llama
    func test_current_llamaBuild_includesGGUF() {
        XCTAssertTrue(CompiledBackends.current.localModelTypes.contains(.gguf))
    }
    #endif

    #if MLX
    func test_current_mlxBuild_includesMLX() {
        XCTAssertTrue(CompiledBackends.current.localModelTypes.contains(.mlx))
    }
    #endif

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
