@preconcurrency import XCTest
@testable import ManifoldUIModelManagement
@testable import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Verifies that `selectedUseCase` reorders `rankedVariants` and that the use-case
/// picker state persists only when a `UserDefaults` is injected.
///
/// Device + memory are injected via `DeviceProfile`, so ranking is deterministic
/// regardless of the host runner's RAM or chip — no real hardware is touched.
@MainActor
final class ModelRecommendationRankingTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    /// A GGUF download fixture. `quant` is encoded into the filename so the production
    /// `DownloadableModel.quantization` regex extracts it.
    private func ggufModel(sizeGB: Double, quant: String, name: String) -> DownloadableModel {
        DownloadableModel(
            repoID: "test/\(name)-GGUF",
            fileName: "\(name).\(quant).gguf",
            displayName: "\(name) \(quant)",
            modelType: .gguf,
            sizeBytes: UInt64(sizeGB * Double(oneGB))
        )
    }

    /// A fixed device profile so bandwidth/memory come from the test, not the host.
    private func device(ramGB: UInt64, bandwidthGBs: Double) -> DeviceProfile {
        let bytes = ramGB * oneGB
        return DeviceProfile(
            physicalMemoryBytes: bytes,
            usableMemoryBytes: bytes,
            memoryBandwidthGBs: bandwidthGBs
        )
    }

    /// Builds a VM whose `searchResults` are populated through the mock + `search()`.
    private func makeViewModel(
        results: [DownloadableModel],
        userDefaults: UserDefaults? = nil
    ) async -> ModelManagementViewModel {
        let mock = MockHuggingFaceService()
        mock.searchResults = results
        let vm = ModelManagementViewModel(
            huggingFaceService: mock,
            deviceCapability: DeviceCapabilityService(physicalMemory: 32 * oneGB),
            userDefaults: userDefaults
        )
        vm.searchQuery = "test"
        await vm.search()
        return vm
    }

    // MARK: - Use-case reorders ranking

    func test_chatPutsFastSmallModelFirst() async {
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let vm = await makeViewModel(results: [capableBig, fastSmall])
        vm.selectedUseCase = .chat

        let ranked = vm.rankedVariants(device: dev)
        XCTAssertEqual(
            ranked.first?.0.fileName, fastSmall.fileName,
            "chat (speed-weighted) should put the fast small model first"
        )
    }

    func test_reasoningFavoursLargerHigherQualityModel() async {
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let vm = await makeViewModel(results: [fastSmall, capableBig])
        vm.selectedUseCase = .reasoning

        let ranked = vm.rankedVariants(device: dev)
        XCTAssertEqual(
            ranked.first?.0.fileName, capableBig.fileName,
            "reasoning (quality-weighted) should put the larger, more-capable model first"
        )
    }

    func test_changingUseCase_flipsTopRankedModel() async {
        // Same inputs, opposite orderings under chat vs reasoning — proves the picker
        // actually drives the order rather than a fixed default.
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let vm = await makeViewModel(results: [fastSmall, capableBig])

        vm.selectedUseCase = .chat
        let chatTop = vm.rankedVariants(device: dev).first?.0.fileName

        vm.selectedUseCase = .reasoning
        let reasoningTop = vm.rankedVariants(device: dev).first?.0.fileName

        XCTAssertNotEqual(
            chatTop, reasoningTop,
            "switching use case should change which model ranks first"
        )
        XCTAssertEqual(chatTop, fastSmall.fileName)
        XCTAssertEqual(reasoningTop, capableBig.fileName)
    }

    func test_rankedVariants_usesSelectedUseCaseByDefault() async {
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let vm = await makeViewModel(results: [fastSmall, capableBig])
        vm.selectedUseCase = .chat

        // No explicit useCase argument → should fall back to selectedUseCase (.chat).
        let ranked = vm.rankedVariants(device: dev)
        XCTAssertEqual(ranked.first?.0.fileName, fastSmall.fileName)
    }

    // MARK: - recommendedModel highlight

    func test_recommendedModel_picksTopRunnableForUseCase() async {
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let vm = await makeViewModel(results: [fastSmall, capableBig])

        vm.selectedUseCase = .chat
        XCTAssertEqual(
            vm.recommendedModel(device: dev)?.fileName, fastSmall.fileName,
            "recommendedModel should mirror the top of the chat-weighted ranking"
        )

        vm.selectedUseCase = .reasoning
        XCTAssertEqual(
            vm.recommendedModel(device: dev)?.fileName, capableBig.fileName,
            "recommendedModel should track the use case like rankedVariants"
        )
    }

    func test_recommendedModel_excludesUnrunnableModels() async {
        // A 4 GB phone can't run a 14 GB model; the recommendation must fall to the
        // only runnable candidate rather than highlighting something that won't load.
        let phone = device(ramGB: 4, bandwidthGBs: 60)
        let fits = ggufModel(sizeGB: 1.5, quant: "Q4_K_M", name: "Fits")
        let tooBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "TooBig")

        let vm = await makeViewModel(results: [tooBig, fits])
        XCTAssertEqual(
            vm.recommendedModel(device: phone)?.fileName, fits.fileName,
            "recommendedModel must skip over-budget models and highlight a runnable one"
        )
    }

    func test_recommendedModel_nilWhenNothingToRank() async {
        let vm = await makeViewModel(results: [])
        XCTAssertNil(
            vm.recommendedModel(device: device(ramGB: 32, bandwidthGBs: 200)),
            "with no search results and no curated recommendations there is nothing to recommend"
        )
    }

    // MARK: - Persistence (injected UserDefaults only)

    func test_selectedUseCase_persistsToInjectedDefaults() async {
        let suite = "ModelRecommendationRankingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removeSuite(named: suite) }

        let vm = await makeViewModel(results: [], userDefaults: defaults)
        vm.selectedUseCase = .coding

        // A fresh VM reading the same store should restore the selection.
        let restored = ModelManagementViewModel(userDefaults: defaults)
        XCTAssertEqual(restored.selectedUseCase, .coding, "use case should round-trip through injected defaults")
    }

    func test_selectedUseCase_withoutDefaults_doesNotPersist() async {
        let vm = await makeViewModel(results: [], userDefaults: nil)
        vm.selectedUseCase = .reasoning

        // A new VM with no injected store must default to .general.
        let fresh = ModelManagementViewModel()
        XCTAssertEqual(fresh.selectedUseCase, .general, "without an injected store the picker stays in-memory")
    }
}
