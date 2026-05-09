import XCTest
@testable import ManifoldTestSupport

final class HardwareRequirementsGGUFTests: XCTestCase {

    private var tempDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        tempDirectory = repoRoot
            .appendingPathComponent(".build/test-temp/HardwareRequirementsGGUFTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    func test_findGGUFModel_missingOverrideFallsBackToSmallestValidCandidate() {
        _ = createGGUFFile("alpha.gguf", size: 12)
        let smallest = createGGUFFile("zeta.gguf", size: 4)
        _ = createGGUFFile("tiny.gguf", size: 1)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "missing"],
            minimumModelSize: 2
        )

        XCTAssertEqual(result?.standardizedFileURL.path, smallest.standardizedFileURL.path)
    }

    func test_findGGUFModel_envOverrideWinsRegardlessOfCandidateSize() {
        _ = createGGUFFile("small.gguf", size: 4)
        let selected = createGGUFFile("large.gguf", size: 24)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "large"],
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, selected.standardizedFileURL.path)
    }

    func test_findGGUFModel_respectsMaximumModelSize() {
        _ = createGGUFFile("too-large.gguf", size: 20)
        let selected = createGGUFFile("fits.gguf", size: 12)
        _ = createGGUFFile("too-small.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            minimumModelSize: 10,
            maximumModelSize: 15
        )

        XCTAssertEqual(result?.standardizedFileURL.path, selected.standardizedFileURL.path)
    }

    func test_publicFindGGUFModel_withoutOptInDoesNotScanDefaultDirectories() {
        let result = HardwareRequirements.findGGUFModel(environment: [:])

        XCTAssertNil(result)
    }

    func test_isValidGGUFModel_rejectsDirectoriesAndTinyFiles() {
        let directory = tempDirectory.appendingPathComponent("fake.gguf", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tiny = createGGUFFile("tiny.gguf", size: 1)

        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(directory, minimumModelSize: 1))
        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(tiny, minimumModelSize: 2))
        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(tiny, minimumModelSize: 1, maximumModelSize: 0))
    }

    @discardableResult
    private func createGGUFFile(_ relativePath: String, size: Int = 4) -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }
}
