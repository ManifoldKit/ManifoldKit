import XCTest
@testable import ManifoldTools

final class VLModelDetectorTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VLModelDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_textOnlyModelDirectory_isNotDetectedAsVL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "hi".write(to: dir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        XCTAssertFalse(VLModelDetector.isVisionLanguageModel(at: dir))
        XCTAssertNil(VLModelDetector.matchedMarkerFile(at: dir))
    }

    func test_preprocessorConfig_isDetectedAsVL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("preprocessor_config.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(VLModelDetector.isVisionLanguageModel(at: dir))
        XCTAssertEqual(VLModelDetector.matchedMarkerFile(at: dir), "preprocessor_config.json")
    }

    func test_processorConfig_isDetectedAsVL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("processor_config.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(VLModelDetector.isVisionLanguageModel(at: dir))
    }

    func test_videoPreprocessorConfig_isDetectedAsVL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("video_preprocessor_config.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(VLModelDetector.isVisionLanguageModel(at: dir))
    }

    func test_nonexistentDirectory_isNotDetectedAsVL() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VLModelDetectorTests-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(VLModelDetector.isVisionLanguageModel(at: dir))
        XCTAssertNil(VLModelDetector.matchedMarkerFile(at: dir))
    }

    func test_fileNotDirectory_isNotDetectedAsVL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("preprocessor_config.json")
        // A *file* at this exact path, not a directory containing it — the
        // marker check requires `directory` itself to be a directory.
        try "{}".write(to: filePath, atomically: true, encoding: .utf8)

        XCTAssertFalse(VLModelDetector.isVisionLanguageModel(at: filePath))
    }
}
