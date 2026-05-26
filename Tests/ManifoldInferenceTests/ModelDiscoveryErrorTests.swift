import XCTest
import ManifoldTestSupport
@testable import ManifoldInference

/// Coverage for the typed ``ModelDiscoveryError`` surface added by #1468.
///
/// The throwing factory ``ModelInfo/load(ggufURL:)`` replaces the previous
/// "silent `nil` return" path with an actionable error a SwiftUI sheet can
/// render. Every branch of that error has an assertion below.
final class ModelDiscoveryErrorTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDiscoveryErrorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Throwing loader branches

    func test_load_validGGUF_returnsModelInfo() throws {
        let url = try writeFile(name: "valid.gguf", contents: makeMinimalGGUFHeader())
        let info = try ModelInfo.load(ggufURL: url)
        XCTAssertEqual(info.modelType, .gguf)
        XCTAssertEqual(info.url, url)
        XCTAssertGreaterThan(info.fileSize, 0)
    }

    func test_load_missingFile_throwsFileMissing() {
        let url = tempDirectory.appendingPathComponent("ghost.gguf")
        XCTAssertThrowsError(try ModelInfo.load(ggufURL: url)) { error in
            guard case .fileMissing(let path) = error as? ModelDiscoveryError else {
                XCTFail("Expected .fileMissing, got \(error)")
                return
            }
            XCTAssertEqual(path, url.path)
        }
    }

    func test_load_directoryAtPath_throwsUnexpectedFileKind() throws {
        let directoryURL = tempDirectory.appendingPathComponent("nested.gguf", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelInfo.load(ggufURL: directoryURL)) { error in
            guard case .unexpectedFileKind = error as? ModelDiscoveryError else {
                XCTFail("Expected .unexpectedFileKind, got \(error)")
                return
            }
        }
    }

    func test_load_wrongExtension_throwsNotGGUF() throws {
        let url = try writeFile(name: "model.bin", contents: Data([0x47, 0x47, 0x55, 0x46]))
        XCTAssertThrowsError(try ModelInfo.load(ggufURL: url)) { error in
            guard case .notGGUF = error as? ModelDiscoveryError else {
                XCTFail("Expected .notGGUF, got \(error)")
                return
            }
        }
    }

    func test_load_wrongMagic_throwsNotGGUF() throws {
        // File has .gguf extension but the first four bytes are not the magic.
        let url = try writeFile(name: "fake.gguf", contents: Data(repeating: 0x00, count: 64))
        XCTAssertThrowsError(try ModelInfo.load(ggufURL: url)) { error in
            guard case .notGGUF(let path) = error as? ModelDiscoveryError else {
                XCTFail("Expected .notGGUF, got \(error)")
                return
            }
            XCTAssertEqual(path, url.path)
        }
    }

    func test_load_metadataParseFailure_returnsModelWithoutTemplate() throws {
        // Build a header with valid magic + version but truncated KV-pair stream,
        // so `readMetadata` throws but `isValidGGUF` (magic-only) passes.
        var data = Data([0x47, 0x47, 0x55, 0x46])          // magic
        appendUInt32(&data, 3)                              // version 3
        appendUInt64(&data, 0)                              // tensor count
        appendUInt64(&data, 5)                              // claim 5 KV entries
        // ...but provide none. readUInt64 will hit EOF and throw .readError.

        let url = try writeFile(name: "truncated.gguf", contents: data)
        let info = try ModelInfo.load(ggufURL: url)
        // Loader is intentionally non-fatal on metadata-parse failures so a
        // user can still try to load and see the real backend error rather
        // than have the file silently disappear from the sheet.
        XCTAssertEqual(info.modelType, .gguf)
        XCTAssertNil(info.detectedPromptTemplate, "Metadata-parse failure must yield nil template")
        XCTAssertNil(info.detectedContextLength)
    }

    // MARK: - Error description

    func test_errorDescription_notGGUF_isActionable() {
        let err = ModelDiscoveryError.notGGUF(path: "/tmp/foo.gguf")
        let description = err.errorDescription ?? ""
        XCTAssertTrue(description.contains("/tmp/foo.gguf"), "Description must include the path: \(description)")
        XCTAssertTrue(
            description.localizedCaseInsensitiveContains("gguf"),
            "Description must mention GGUF for actionability: \(description)"
        )
    }

    func test_errorDescription_notReadable_suggestsRecovery() {
        let err = ModelDiscoveryError.notReadable(path: "/var/private/foo.gguf", reason: "sandbox")
        let description = err.errorDescription ?? ""
        XCTAssertTrue(description.contains("/var/private/foo.gguf"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("import"),
                      "Description must point users at an actionable next step: \(description)")
    }

    // MARK: - Helpers

    private func writeFile(name: String, contents: Data) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// Minimal valid GGUF v3 header with zero metadata entries.
    private func makeMinimalGGUFHeader() -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])  // magic
        appendUInt32(&data, 3)                      // version
        appendUInt64(&data, 0)                      // tensor count
        appendUInt64(&data, 0)                      // metadata KV count
        return data
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
