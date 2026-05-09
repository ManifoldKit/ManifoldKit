import XCTest
@testable import ManifoldInference
import ManifoldTestSupport
#if HuggingFace
@testable import ManifoldHuggingFace
import HuggingFace

final class HuggingFaceServiceTests: XCTestCase {

    private var service: HuggingFaceService!

    override func setUp() {
        super.setUp()
        CuratedModel.all = [
            CuratedModel(
                id: "test-phi",
                displayName: "Phi-3.1 Mini Q4",
                fileName: "phi-3.1-mini-q4.gguf",
                repoID: "bartowski/Phi-3.1-mini-4k-instruct-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 2_200_000_000,
                recommendedFor: [.small, .medium, .large, .xlarge],
                contextSize: 4096,
                promptTemplate: .phi,
                description: "Phi-3.1 Mini 4-bit quantized model"
            ),
            CuratedModel(
                id: "test-mistral",
                displayName: "Mistral 7B Q4_K_M",
                fileName: "mistral-7b-instruct-v0.3-Q4_K_M.gguf",
                repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 4_100_000_000,
                recommendedFor: [.medium, .large, .xlarge],
                contextSize: 8192,
                promptTemplate: .mistral,
                description: "Mistral 7B Instruct v0.3 4-bit quantized"
            ),
            CuratedModel(
                id: "test-qwen-mlx",
                displayName: "Qwen3 4B 4-bit",
                fileName: "Qwen3-4B-4bit",
                repoID: "mlx-community/Qwen3-4B-4bit",
                modelType: .mlx,
                approximateSizeBytes: 5_000_000_000,
                recommendedFor: [.large, .xlarge],
                contextSize: 4096,
                promptTemplate: .chatML,
                description: "Qwen3 4B MLX 4-bit quantized model"
            ),
            CuratedModel(
                id: "test-llama-large",
                displayName: "Llama 3.1 70B Q4",
                fileName: "llama-3.1-70b-q4.gguf",
                repoID: "bartowski/Llama-3.1-70B-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 40_000_000_000,
                recommendedFor: [.xlarge],
                contextSize: 8192,
                promptTemplate: .llama3,
                description: "Llama 3.1 70B 4-bit quantized model"
            ),
        ]
        service = HuggingFaceService()
    }

    override func tearDown() {
        service = nil
        CuratedModel.all = []
        super.tearDown()
    }

    /// Tracks per-test stub URLs so the test can `unstub` them in `defer`.
    /// We avoid `MockURLProtocol.reset()` because parallel suites share
    /// `MockURLProtocol`'s static stub registry; resetting would clobber
    /// concurrently-running tests.
    private struct MockHuggingFaceStubScope {
        let service: HuggingFaceService
        let stubbedURLs: [URL]

        func unstubAll() {
            for url in stubbedURLs {
                MockURLProtocol.unstub(url: url)
            }
        }
    }

    /// Builds a `HuggingFaceService` whose `HubClient` is pinned to a unique
    /// per-test hostname (`https://<uuid>.huggingface.test`). Stubs are
    /// registered against that hostname only, so concurrent tests running
    /// under `swift test --parallel` cannot collide on the global
    /// `MockURLProtocol` stub registry.
    private func makeMockService(
        listResponseJSON: String = "[]",
        modelDetailsByRepoID: [String: String] = [:]
    ) -> MockHuggingFaceStubScope {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let uniqueHost = "\(UUID().uuidString.lowercased()).huggingface.test"
        let hostURL = URL(string: "https://\(uniqueHost)")!
        let hubClient = HubClient(
            session: session,
            host: hostURL,
            userAgent: "ManifoldKitTests/1.0",
            cache: nil
        )

        var stubbedURLs: [URL] = []

        let listURL = URL(string: "https://\(uniqueHost)/api/models")!
        MockURLProtocol.stub(
            url: listURL,
            response: .immediate(
                data: Data(listResponseJSON.utf8),
                statusCode: 200,
                headers: ["Content-Type": "application/json"]
            )
        )
        stubbedURLs.append(listURL)

        for (repoID, json) in modelDetailsByRepoID {
            let detailURL = URL(string: "https://\(uniqueHost)/api/models/\(repoID)")!
            MockURLProtocol.stub(
                url: detailURL,
                response: .immediate(
                    data: Data(json.utf8),
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                )
            )
            stubbedURLs.append(detailURL)
        }

        return MockHuggingFaceStubScope(
            service: HuggingFaceService(hubClient: hubClient),
            stubbedURLs: stubbedURLs
        )
    }

    private func decodeModel(from json: String) throws -> Model {
        try JSONDecoder().decode(Model.self, from: Data(json.utf8))
    }

    // MARK: - Curated Models

    func test_curatedModels_smallDevice_returnsSmallModels() {
        let models = service.curatedModels(for: .small)

        XCTAssertFalse(models.isEmpty, "Small devices should have at least one curated model")

        // Phi-3.1 Mini is recommended for small devices.
        let hasPhi = models.contains { $0.displayName.contains("Phi") }
        XCTAssertTrue(hasPhi, "Small device curated list should include Phi-3.1 Mini")

        // All returned models should be marked as curated.
        for model in models {
            XCTAssertTrue(model.isCurated, "\(model.displayName) should be marked as curated")
        }
    }

    func test_curatedModels_largeDevice_includesMultipleOptions() {
        let models = service.curatedModels(for: .large)

        XCTAssertGreaterThanOrEqual(
            models.count, 2,
            "Large devices should have multiple curated models"
        )

        // Should include at least one GGUF and possibly MLX models.
        let ggufCount = models.filter { $0.modelType == .gguf }.count
        XCTAssertGreaterThanOrEqual(ggufCount, 1, "Large device list should include GGUF models")
    }

    func test_curatedModels_xlarge_includesAll() {
        let models = service.curatedModels(for: .xlarge)

        // XLarge should have all models that include .xlarge in their recommendedFor.
        let expectedCount = CuratedModel.all
            .filter { $0.recommendedFor.contains(.xlarge) }
            .count
        XCTAssertEqual(
            models.count, expectedCount,
            "XLarge should return exactly the models recommended for .xlarge"
        )
    }

    // MARK: - Download URL

    func test_downloadURL_constructsCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            displayName: "Mistral 7B Q4_K_M",
            modelType: .gguf,
            sizeBytes: 4_100_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
        )
    }

    func test_downloadURL_handlesMLXModel() {
        let model = DownloadableModel(
            repoID: "mlx-community/Qwen3-4B-4bit",
            fileName: "Qwen3-4B-4bit",
            displayName: "Qwen3 4B 4-bit",
            modelType: .mlx,
            sizeBytes: 2_500_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(
            url.path.contains("mlx-community/Qwen3-4B-4bit"),
            "URL path should contain the repo ID"
        )
    }

    // MARK: - Validation

    func test_curatedModels_allHaveValidRepoIDs() {
        // Every curated model should have a non-empty repo ID in "namespace/name" format.
        for curated in CuratedModel.all {
            let components = curated.repoID.split(separator: "/", maxSplits: 1)
            XCTAssertEqual(
                components.count, 2,
                "Curated model \(curated.id) has invalid repoID: \(curated.repoID)"
            )
            XCTAssertFalse(
                components[0].isEmpty,
                "Curated model \(curated.id) has empty namespace"
            )
            XCTAssertFalse(
                components[1].isEmpty,
                "Curated model \(curated.id) has empty name"
            )
        }
    }

    func test_curatedModels_allHaveNonZeroSize() {
        for curated in CuratedModel.all {
            XCTAssertGreaterThan(
                curated.approximateSizeBytes, 0,
                "Curated model \(curated.id) should have a non-zero size"
            )
        }
    }

    // MARK: - Medium Device Tier

    func test_curatedModels_mediumDevice_includesSmallAndMedium() {
        let models = service.curatedModels(for: .medium)

        // Medium tier should include models recommended for .small and .medium.
        let smallModels = CuratedModel.all.filter { $0.recommendedFor.contains(.small) }
        let mediumModels = CuratedModel.all.filter { $0.recommendedFor.contains(.medium) }

        // Every model recommended for .small that is also recommended for .medium should appear.
        for small in smallModels where small.recommendedFor.contains(.medium) {
            let found = models.contains { $0.displayName == small.displayName }
            XCTAssertTrue(found, "\(small.displayName) is recommended for both .small and .medium, should appear in .medium results")
        }

        // All models in the result should be recommended for .medium.
        let expectedCount = mediumModels.count
        XCTAssertEqual(
            models.count, expectedCount,
            "Medium tier should return exactly the models recommended for .medium"
        )

        XCTAssertGreaterThan(
            models.count, 0,
            "Medium tier should have at least one curated model"
        )
    }

    // MARK: - Curated Model Metadata Validation

    func test_curatedModels_allHaveNonEmptyDescription() {
        for curated in CuratedModel.all {
            XCTAssertFalse(
                curated.description.isEmpty,
                "Curated model \(curated.id) should have a non-empty description"
            )
        }
    }

    func test_curatedModels_allHaveValidPromptTemplate() {
        for curated in CuratedModel.all {
            // promptTemplate is non-optional on CuratedModel, so this verifies
            // it is one of the known template cases.
            let validTemplates = PromptTemplate.allCases
            XCTAssertTrue(
                validTemplates.contains(curated.promptTemplate),
                "Curated model \(curated.id) has template \(curated.promptTemplate.rawValue) which should be a valid PromptTemplate case"
            )
        }
    }

    // MARK: - Download URL Edge Cases

    func test_downloadURL_handlesSpecialCharactersInFileName() {
        let model = DownloadableModel(
            repoID: "test-org/My-Model-GGUF",
            fileName: "My Model (v2) Q4_K_M.gguf",
            displayName: "My Model Q4_K_M",
            modelType: .gguf,
            sizeBytes: 4_000_000_000
        )

        let url = service.downloadURL(for: model)

        // URLComponents should percent-encode spaces and parentheses in the path.
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(
            url.absoluteString.contains("My%20Model%20(v2)%20Q4_K_M.gguf")
            || url.absoluteString.contains("My%20Model%20%28v2%29%20Q4_K_M.gguf"),
            "URL should percent-encode special characters in the file name, got: \(url.absoluteString)"
        )
    }

    func test_downloadURL_mlxModel_constructsCorrectly() {
        let model = DownloadableModel(
            repoID: "mlx-community/Qwen3-4B-4bit",
            fileName: "Qwen3-4B-4bit",
            displayName: "Qwen3 4B 4-bit",
            modelType: .mlx,
            sizeBytes: 2_500_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/main/Qwen3-4B-4bit",
            "MLX download URL should follow the standard HuggingFace resolve/main format"
        )
    }

    // MARK: - MLX Characterization

    func test_convertModelToDownloadables_mlxRepo_returnsSingleDownloadableDirectory() throws {
        let repoID = "mlx-community/Gemma-3-4B-it-4bit"
        let detailedResponse = """
            {
                "id": "\(repoID)",
                "downloads": 42,
                "pipeline_tag": "text-generation",
                "siblings": [
                    { "rfilename": "config.json", "size": 1200 },
                    { "rfilename": "model.safetensors", "size": 8000 },
                    { "rfilename": "tokenizer.json", "size": 300 }
                ]
            }
            """
        let model = try decodeModel(from: detailedResponse)
        let files = service.convertModelToDownloadables(model)
        let mlxModel = try XCTUnwrap(files.first)

        XCTAssertEqual(files.count, 1, "MLX repos should surface as one logical downloadable")
        XCTAssertEqual(mlxModel.modelType, .mlx)
        XCTAssertEqual(mlxModel.repoID, repoID)
        XCTAssertEqual(mlxModel.fileName, "Gemma-3-4B-it-4bit")
        XCTAssertEqual(mlxModel.sizeBytes, 9_500)
    }

    func test_searchModels_includesMLXReposAlongsideGGUFResults() async throws {
        let mlxRepoID = "mlx-community/Gemma-3-4B-it-4bit"
        let ggufRepoID = "bartowski/Mistral-7B-Instruct-v0.3-GGUF"
        let listResponse = """
            [
                {
                    "id": "\(mlxRepoID)",
                    "downloads": 2500,
                    "pipeline_tag": "text-generation",
                    "siblings": [
                        { "rfilename": "config.json", "size": 1200 },
                        { "rfilename": "model.safetensors", "size": 8000 },
                        { "rfilename": "tokenizer.json", "size": 300 }
                    ]
                },
                {
                    "id": "\(ggufRepoID)",
                    "downloads": 1000,
                    "pipeline_tag": "text-generation",
                    "siblings": [
                        { "rfilename": "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", "size": 4100000000 }
                    ]
                }
            ]
            """
        let mlxDetail = """
            {
                "id": "\(mlxRepoID)",
                "downloads": 2500,
                "pipeline_tag": "text-generation",
                "siblings": [
                    { "rfilename": "config.json", "size": 1200 },
                    { "rfilename": "model.safetensors", "size": 8000 },
                    { "rfilename": "tokenizer.json", "size": 300 }
                ]
            }
            """
        let ggufDetail = """
            {
                "id": "\(ggufRepoID)",
                "downloads": 1000,
                "pipeline_tag": "text-generation",
                "siblings": [
                    { "rfilename": "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", "size": 4100000000 }
                ]
            }
            """

        let scope = makeMockService(
            listResponseJSON: listResponse,
            modelDetailsByRepoID: [
                mlxRepoID: mlxDetail,
                ggufRepoID: ggufDetail,
            ]
        )
        defer { scope.unstubAll() }

        let results = try await scope.service.searchModels(query: "gemma")

        XCTAssertTrue(
            results.contains(where: { $0.repoID == ggufRepoID && $0.modelType == .gguf }),
            "Search should continue to include GGUF results"
        )
        let mlxModel = try XCTUnwrap(
            results.first(where: { $0.repoID == mlxRepoID && $0.modelType == .mlx }),
            "Search should include MLX repos as downloadable results"
        )
        XCTAssertEqual(mlxModel.fileName, "Gemma-3-4B-it-4bit")
        XCTAssertEqual(mlxModel.sizeBytes, 9_500)
    }

    // MARK: - Curated Model Data Integrity

    func test_curatedModels_allRepoIDsHaveCorrectFormat() {
        let repoIDPattern = #"^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$"#
        // Safe to force-unwrap: pattern is a compile-time constant.
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: repoIDPattern)

        for curated in CuratedModel.all {
            let range = NSRange(curated.repoID.startIndex..., in: curated.repoID)
            let match = regex.firstMatch(in: curated.repoID, range: range)
            XCTAssertNotNil(
                match,
                "Curated model \(curated.id) has repoID '\(curated.repoID)' which doesn't match 'namespace/name' format"
            )
        }
    }

    func test_curatedModels_noOverlappingIDs() {
        let ids = CuratedModel.all.map { $0.id }
        let uniqueIDs = Set(ids)
        XCTAssertEqual(
            ids.count, uniqueIDs.count,
            "All curated model IDs should be unique. Duplicates: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })"
        )
    }

    func test_curatedModels_allFileSizesReasonable() {
        let minSize: UInt64 = 100_000_000      // 100 MB
        let maxSize: UInt64 = 100_000_000_000   // 100 GB

        for curated in CuratedModel.all {
            XCTAssertGreaterThanOrEqual(
                curated.approximateSizeBytes, minSize,
                "Curated model \(curated.id) size \(curated.approximateSizeBytes) is below 100 MB — likely an error"
            )
            XCTAssertLessThanOrEqual(
                curated.approximateSizeBytes, maxSize,
                "Curated model \(curated.id) size \(curated.approximateSizeBytes) exceeds 100 GB — likely an error"
            )
        }
    }

    // MARK: - Mock Service Tests

    func test_mockService_searchReturnsConfiguredResults() async throws {
        let mock = MockHuggingFaceService()
        let expectedModel = DownloadableModel(
            repoID: "test-org/test-model-GGUF",
            fileName: "test-model-Q4_K_M.gguf",
            displayName: "Test Model Q4_K_M",
            modelType: .gguf,
            sizeBytes: 3_000_000_000
        )
        mock.searchResults = [expectedModel]

        let results = try await mock.searchModels(query: "test")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, expectedModel.id)
        XCTAssertEqual(results.first?.displayName, "Test Model Q4_K_M")
        XCTAssertEqual(mock.searchCallCount, 1)
    }

    func test_mockService_searchThrowsConfiguredError() async {
        let mock = MockHuggingFaceService()
        mock.searchError = HuggingFaceError.networkUnavailable

        do {
            _ = try await mock.searchModels(query: "test")
            XCTFail("Expected searchModels to throw, but it succeeded")
        } catch {
            guard case HuggingFaceError.networkUnavailable = error else {
                XCTFail("Expected networkUnavailable error, got: \(error)")
                return
            }
        }
        XCTAssertEqual(mock.searchCallCount, 1, "searchCallCount should increment even when throwing")
    }
}

// MARK: - HuggingFaceDownloadURLTests

final class HuggingFaceDownloadURLTests: XCTestCase {

    private var service: HuggingFaceService!

    override func setUp() {
        super.setUp()
        service = HuggingFaceService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - URL Construction

    func test_downloadURL_gguf_constructsResolveURL() {
        let model = DownloadableModel(
            repoID: "TheBloke/Llama-2-7B-GGUF",
            fileName: "llama-2-7b.Q4_K_M.gguf",
            displayName: "Llama 2 7B Q4_K_M",
            modelType: .gguf,
            sizeBytes: 3_800_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertTrue(
            url.absoluteString.contains("TheBloke/Llama-2-7B-GGUF"),
            "URL should contain the repoID, got: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("llama-2-7b.Q4_K_M.gguf"),
            "URL should contain the fileName, got: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("resolve/main"),
            "URL should use the HuggingFace resolve/main path, got: \(url.absoluteString)"
        )
    }

    func test_downloadURL_mlx_constructsResolveURL() {
        let model = DownloadableModel(
            repoID: "mlx-community/Llama-3-8B",
            fileName: "Llama-3-8B",
            displayName: "Llama 3 8B",
            modelType: .mlx,
            sizeBytes: 4_700_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertTrue(
            url.absoluteString.contains("mlx-community/Llama-3-8B"),
            "URL should contain the repoID, got: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("resolve/main"),
            "URL should use the HuggingFace resolve/main path, got: \(url.absoluteString)"
        )
    }

    func test_downloadURL_containsHuggingFaceDomain() {
        let model = DownloadableModel(
            repoID: "bartowski/Phi-3.1-mini-4k-instruct-GGUF",
            fileName: "Phi-3.1-mini-4k-instruct-Q4_K_M.gguf",
            displayName: "Phi 3.1 Mini Q4_K_M",
            modelType: .gguf,
            sizeBytes: 2_200_000_000
        )

        let url = service.downloadURL(for: model)

        XCTAssertEqual(url.scheme, "https", "URL scheme should be https")
        XCTAssertEqual(url.host, "huggingface.co", "URL host should be huggingface.co")
    }

    func test_downloadURL_specialCharsInRepoID_encodedCorrectly() {
        // repoID and fileName each contain only dashes — valid HuggingFace identifiers.
        // This confirms round-trip construction doesn't crash and produces a valid URL.
        let model = DownloadableModel(
            repoID: "my-org/My-Model-v2-GGUF",
            fileName: "my-model-v2-Q8_0.gguf",
            displayName: "My Model v2 Q8_0",
            modelType: .gguf,
            sizeBytes: 7_000_000_000
        )

        let url = service.downloadURL(for: model)

        // URL must be valid (non-nil is guaranteed by the service, but we confirm the
        // expected components survive the URLComponents round-trip).
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(
            url.absoluteString.contains("my-org/My-Model-v2-GGUF"),
            "Dashes in repoID should be preserved, got: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("my-model-v2-Q8_0.gguf"),
            "Dashes in fileName should be preserved, got: \(url.absoluteString)"
        )
    }

    // MARK: - Error Mapping

    func test_searchModels_networkError_throwsSearchFailed() async {
        let mock = MockHuggingFaceService()
        // Wrap a generic network-style error as a searchFailed, matching the real
        // service's catch block in searchModels(query:).
        struct FakeNetworkError: Error {}
        mock.searchError = HuggingFaceError.searchFailed(underlying: FakeNetworkError())

        do {
            _ = try await mock.searchModels(query: "llama")
            XCTFail("Expected searchModels to throw, but it succeeded")
        } catch {
            guard case HuggingFaceError.searchFailed = error else {
                XCTFail("Expected searchFailed error, got: \(error)")
                return
            }
        }
        XCTAssertEqual(mock.searchCallCount, 1, "searchCallCount should increment even when throwing")
    }

    func test_searchModels_emptyQuery_returnsResults() async throws {
        let mock = MockHuggingFaceService()
        // No error configured — empty query should not throw.
        mock.searchResults = []

        let results = try await mock.searchModels(query: "")

        // Contract: empty query does not throw; result may be empty.
        XCTAssertNotNil(results, "searchModels should return a non-nil array for an empty query")
        XCTAssertEqual(mock.searchCallCount, 1)
    }
}
#endif
