import XCTest
@testable import BaseChatInference

final class CompiledBackendsTests: XCTestCase {

    func test_current_profileMatchesTraits() {
        let compiled = CompiledBackends.current

        XCTAssertEqual(compiled.buildProfile, expectedProfile(for: compiled.traits))
    }

    func test_downloadableModelTypes_areSubsetOfLocalModelTypes() {
        let compiled = CompiledBackends.current

        XCTAssertTrue(compiled.downloadableModelTypes.isSubset(of: compiled.localModelTypes))
        XCTAssertTrue(compiled.downloadableModelTypes.isSubset(of: [.gguf, .mlx]))
    }

    func test_presentationFlags_followCompiledSets() {
        let compiled = CompiledBackends.current

        XCTAssertEqual(compiled.shouldPresentModelDownloads, !compiled.downloadableModelTypes.isEmpty)
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
        let compiled = CompiledBackends.current

        XCTAssertEqual(APIProvider.availableInBuild, compiled.orderedCloudProviders)
    }

    @MainActor
    func test_frameworkCapabilityService_exposesCompiledBackends() {
        let service = FrameworkCapabilityService(inferenceService: InferenceService())

        XCTAssertEqual(service.compiledBackends, .current)
    }

    private func expectedProfile(for traits: Set<BackendBuildTrait>) -> BackendBuildProfile {
        switch (traits.contains(.ollama), traits.contains(.cloudSaaS)) {
        case (false, false): .offline
        case (true, false): .selfHosted
        case (false, true): .saas
        case (true, true): .full
        }
    }
}
