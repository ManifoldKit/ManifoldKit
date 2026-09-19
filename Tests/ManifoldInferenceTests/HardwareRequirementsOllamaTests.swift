import XCTest
@testable import ManifoldTestSupport

final class HardwareRequirementsOllamaTests: XCTestCase {

    // MARK: - Helpers

    private func model(name: String, parameterSize: String) -> [String: Any] {
        ["name": name, "details": ["parameter_size": parameterSize]]
    }

    // MARK: - selectOllamaModel

    func test_picks7BModelFromMixedList() {
        let models = [
            model(name: "phi:3b", parameterSize: "3.0B"),
            model(name: "llama3:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "llama3:7b")
    }

    func test_picks8BModel() {
        let models = [
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "llama3.1:8b")
    }

    func test_fallsBackToFirstWhenNoneInRange() {
        let models = [
            model(name: "tinyllama:1b", parameterSize: "1.0B"),
            model(name: "phi:3b", parameterSize: "3.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "tinyllama:1b")
    }

    func test_emptyModelList_returnsNil() {
        let result = HardwareRequirements.selectOllamaModel(from: [])
        XCTAssertNil(result)
    }

    func test_missingDetailsField_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            ["name": "broken-model"],
            model(name: "fallback:7b", parameterSize: "7.2B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "fallback:7b")
    }

    func test_missingParameterSize_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            ["name": "no-size", "details": ["family": "llama"]],
            model(name: "good:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "good:8b")
    }

    func test_customSizeRange() {
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            preferredSizeRange: 12.0...14.0
        )
        XCTAssertEqual(result, "llama3:13b")
    }

    func test_unparseableParameterSize_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            model(name: "weird:latest", parameterSize: "large"),
            model(name: "fallback:3b", parameterSize: "3.0B"),
        ]
        // Neither model is in the default 6.5...9.0 range, so falls back to first.
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "weird:latest")
    }

    func test_multipleModelsInRange_returnsFirst() {
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "mistral:7b")
    }

    // MARK: - OLLAMA_TEST_MODEL env override

    func test_ollamaTestModelEnv_overridesSizeBasedSelection() {
        // Without the override the 7.2B model wins; with the override pinning
        // the 13B model, selection honours the env var.
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            environment: ["OLLAMA_TEST_MODEL": "llama3:13b"]
        )
        XCTAssertEqual(result, "llama3:13b")
    }

    func test_ollamaTestModelEnv_pinsOutOfRangeModel() {
        // The override names a 3B model that the default range would skip.
        let models = [
            model(name: "phi:3b", parameterSize: "3.0B"),
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            environment: ["OLLAMA_TEST_MODEL": "phi:3b"]
        )
        XCTAssertEqual(result, "phi:3b")
    }

    func test_ollamaTestModelEnv_notInstalled_fallsThrough() {
        // Override is set but the named model is not installed — fall through
        // to the size-based selection rather than returning nil so the suite
        // still runs.
        let models = [
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            environment: ["OLLAMA_TEST_MODEL": "not-installed:latest"]
        )
        XCTAssertEqual(result, "llama3.1:8b")
    }

    func test_ollamaTestModelEnv_emptyValue_ignored() {
        // Treat empty-string as "unset" so `OLLAMA_TEST_MODEL=""` doesn't fall
        // into the override branch and skip size-based selection.
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            environment: ["OLLAMA_TEST_MODEL": ""]
        )
        XCTAssertEqual(result, "mistral:7b")
    }

    func test_ollamaTestModelEnv_absent_usesSizeBased() {
        // No override key at all — unchanged size-based behaviour.
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            environment: [:]
        )
        XCTAssertEqual(result, "mistral:7b")
    }

    // MARK: - Named and vision-capable discovery

    func test_nameSubstringSelection_explicitOverrideWinsWithoutLegacyFragment() {
        let models = [
            model(name: "qwen2.5vl:3b", parameterSize: "3.0B"),
            model(name: "gemma3:4b", parameterSize: "4.0B"),
        ]

        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            nameContains: "vl",
            environment: ["OLLAMA_TEST_MODEL": "gemma3:4b"]
        )

        XCTAssertEqual(result, "gemma3:4b")
    }

    func test_visionSelection_discoversCapableModelWithoutLegacyNameFragment() {
        let names = ["llama3.1:8b", "gemma3:4b"]

        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: names,
            isVisionCapable: { $0 == "gemma3:4b" }
        )

        XCTAssertEqual(result, "gemma3:4b")
    }

    func test_visionSelection_explicitCapableOverrideWins() {
        let names = ["qwen2.5vl:3b", "gemma3:4b"]

        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: names,
            environment: ["OLLAMA_TEST_MODEL": "gemma3:4b"],
            isVisionCapable: { _ in true }
        )

        XCTAssertEqual(result, "gemma3:4b")
    }

    func test_visionSelection_explicitIncapableOverrideFailsClosed() {
        let names = ["qwen2.5vl:3b", "llama3.1:8b"]

        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: names,
            environment: ["OLLAMA_TEST_MODEL": "llama3.1:8b"],
            isVisionCapable: { $0 == "qwen2.5vl:3b" }
        )

        XCTAssertNil(result)
    }

    func test_visionSelection_explicitMissingOverrideFailsClosed() {
        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: ["qwen2.5vl:3b"],
            environment: ["OLLAMA_TEST_MODEL": "gemma3:4b"],
            isVisionCapable: { _ in true }
        )

        XCTAssertNil(result)
    }

    func test_visionSelection_emptyListReturnsNilWithoutProbing() {
        var probed = false

        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: [],
            isVisionCapable: { _ in
                probed = true
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(probed)
    }

    func test_visionSelection_noCapableModelsReturnsNil() {
        let result = HardwareRequirements.selectOllamaVisionCapableModel(
            from: ["llama3.1:8b", "phi4:latest"],
            isVisionCapable: { _ in false }
        )

        XCTAssertNil(result)
    }
}
