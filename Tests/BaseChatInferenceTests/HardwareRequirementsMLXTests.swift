import XCTest
@testable import BaseChatTestSupport

final class HardwareRequirementsMLXTests: XCTestCase {

    private var tempDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fm.temporaryDirectory
            .appendingPathComponent("HardwareRequirementsMLXTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func test_isValidMLXDirectory_withConfigAndSafetensors_returnsTrue() {
        createValidMLXDirectory(at: tempDirectory)
        XCTAssertTrue(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_withMultipleSafetensors_returnsTrue() {
        createFile("config.json", in: tempDirectory, contents: #"{"model_type":"llama"}"#)
        createFile("tokenizer.model", in: tempDirectory)
        createFile("model-00001-of-00002.safetensors", in: tempDirectory)
        createFile("model-00002-of-00002.safetensors", in: tempDirectory)
        XCTAssertTrue(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_missingConfig_returnsFalse() {
        createFile("tokenizer.json", in: tempDirectory)
        createFile("model.safetensors", in: tempDirectory)
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_missingModelType_returnsFalse() {
        createFile("config.json", in: tempDirectory, contents: "{}")
        createFile("tokenizer.json", in: tempDirectory)
        createFile("model.safetensors", in: tempDirectory)
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_missingSafetensors_returnsFalse() {
        createFile("config.json", in: tempDirectory, contents: #"{"model_type":"llama"}"#)
        createFile("tokenizer.json", in: tempDirectory)
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_missingTokenizer_returnsFalse() {
        createFile("config.json", in: tempDirectory, contents: #"{"model_type":"llama"}"#)
        createFile("model.safetensors", in: tempDirectory)
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_emptyDirectory_returnsFalse() {
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_fileInsteadOfDirectory_returnsFalse() {
        let fileURL = tempDirectory.appendingPathComponent("not-a-directory")
        fm.createFile(atPath: fileURL.path, contents: Data("hello".utf8))
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(fileURL))
    }

    func test_findMLXModelDirectory_prefersEnvOverride() {
        let alpha = tempDirectory.appendingPathComponent("alpha-model", isDirectory: true)
        let beta = tempDirectory.appendingPathComponent("beta-model", isDirectory: true)
        createValidMLXDirectory(at: alpha)
        createValidMLXDirectory(at: beta)

        let result = HardwareRequirements.findMLXModelDirectory(
            in: [tempDirectory],
            environment: ["MLX_TEST_MODEL": "beta"]
        )

        XCTAssertEqual(result?.standardizedFileURL.path, beta.standardizedFileURL.path)
    }

    func test_findMLXModelDirectory_searchesOneNestedDirectoryLevel() {
        let nested = tempDirectory
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("gemma-4-mini", isDirectory: true)
        createValidMLXDirectory(at: nested)

        let result = HardwareRequirements.findMLXModelDirectory(
            in: [tempDirectory],
            nameContains: "gemma"
        )

        XCTAssertEqual(result?.standardizedFileURL.path, nested.standardizedFileURL.path)
    }

    func test_findMLXModelDirectory_overrideFallsBackToFirstSortedCandidate() {
        let zeta = tempDirectory.appendingPathComponent("zeta-model", isDirectory: true)
        let alpha = tempDirectory.appendingPathComponent("alpha-model", isDirectory: true)
        createValidMLXDirectory(at: zeta)
        createValidMLXDirectory(at: alpha)

        let result = HardwareRequirements.findMLXModelDirectory(
            in: [tempDirectory],
            environment: ["MLX_TEST_MODEL": "missing"]
        )

        XCTAssertEqual(result?.standardizedFileURL.path, alpha.standardizedFileURL.path)
    }

    private func createValidMLXDirectory(at directory: URL) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        createFile("config.json", in: directory, contents: #"{"model_type":"llama"}"#)
        createFile("tokenizer.json", in: directory)
        createFile("model.safetensors", in: directory)
    }

    @discardableResult
    private func createFile(_ name: String, in directory: URL, contents: String = "") -> URL {
        let url = directory.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }
}
