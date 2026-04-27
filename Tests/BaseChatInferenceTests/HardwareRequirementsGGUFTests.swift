import XCTest
@testable import BaseChatTestSupport

final class HardwareRequirementsGGUFTests: XCTestCase {

    private var tempDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fm.temporaryDirectory
            .appendingPathComponent("HardwareRequirementsGGUFTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func test_findGGUFModel_prefersEnvOverride() {
        let alpha = createGGUFFile("alpha-model.gguf")
        _ = createGGUFFile("beta-model.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "alpha"],
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, alpha.standardizedFileURL.path)
    }

    func test_findGGUFModel_searchesOneNestedDirectoryLevel() {
        let nested = createGGUFFile("qwen/qwen3-thinking.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "thinking",
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, nested.standardizedFileURL.path)
    }

    func test_findGGUFModel_overrideFallsBackToFirstSortedCandidate() {
        _ = createGGUFFile("zeta.gguf")
        let alpha = createGGUFFile("alpha.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "missing"],
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, alpha.standardizedFileURL.path)
    }

    func test_isValidGGUFModel_rejectsDirectoriesAndTinyFiles() {
        let directory = tempDirectory.appendingPathComponent("fake.gguf", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tiny = createGGUFFile("tiny.gguf", size: 1)

        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(directory, minimumModelSize: 1))
        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(tiny, minimumModelSize: 2))
    }

    @discardableResult
    private func createGGUFFile(_ relativePath: String, size: Int = 4) -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }
}
