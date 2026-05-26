import XCTest
import ManifoldTestSupport
@testable import ManifoldInference

/// Coverage for the `~/Documents/Models` fallback discovery path + the
/// error-reporting variant of ``ModelStorageService/discoverModels(reportingErrors:)``
/// added by #1468. Both paths are exercised through fully isolated scratch
/// directories — the production user `~/Documents` is never touched.
final class ModelStorageServiceFallbackTests: XCTestCase {

    private var primaryDirectory: URL!
    private var fallbackDirectory: URL!
    private var service: ModelStorageService!

    override func setUp() {
        super.setUp()
        primaryDirectory = makeScratchDirectory(named: "primary")
        fallbackDirectory = makeScratchDirectory(named: "fallback")
        service = ModelStorageService(
            fileManager: .default,
            baseDirectory: primaryDirectory,
            bundleIdentifier: nil,
            includeUserDocumentsFallback: true,
            fallbackDirectoryOverride: fallbackDirectory
        )
        try? service.ensureModelsDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: primaryDirectory)
        try? FileManager.default.removeItem(at: fallbackDirectory)
        primaryDirectory = nil
        fallbackDirectory = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Fallback inclusion

    func test_discoverModels_includesFallbackDirectory() throws {
        try writeMinimalGGUF(at: primaryDirectory.appendingPathComponent("primary.gguf"))
        try writeMinimalGGUF(at: fallbackDirectory.appendingPathComponent("documents.gguf"))

        let models = service.discoverModels()
        let names = Set(models.map { $0.fileName })
        XCTAssertTrue(names.contains("primary.gguf"))
        XCTAssertTrue(names.contains("documents.gguf"),
                      "Documents/Models fallback must be surfaced when the user follows the CLI quickstart guide. Got: \(names)")
    }

    func test_discoverModels_appScopedTakesPrecedence_overFallback() throws {
        // Same filename in both directories. The stable ModelInfo ID is derived
        // from the resolved URL — different files yield different IDs — but the
        // assertion here is that the app-scoped scan runs first and surfaces its
        // entry, and the fallback entry is appended.
        try writeMinimalGGUF(at: primaryDirectory.appendingPathComponent("shared.gguf"))
        try writeMinimalGGUF(at: fallbackDirectory.appendingPathComponent("shared.gguf"))

        let models = service.discoverModels()
        let primaryHits = models.filter { $0.url.resolvingSymlinksInPath().path.hasPrefix(primaryDirectory.resolvingSymlinksInPath().path) }
        XCTAssertEqual(primaryHits.count, 1, "App-scoped scan must yield exactly one entry")
        XCTAssertEqual(primaryHits.first?.fileName, "shared.gguf")
    }

    func test_discoverModels_fallbackOff_ignoresUserDocuments() throws {
        let strictService = ModelStorageService(
            fileManager: .default,
            baseDirectory: primaryDirectory,
            bundleIdentifier: nil,
            includeUserDocumentsFallback: false,
            fallbackDirectoryOverride: fallbackDirectory
        )
        try? strictService.ensureModelsDirectory()
        try writeMinimalGGUF(at: fallbackDirectory.appendingPathComponent("documents.gguf"))

        let models = strictService.discoverModels()
        XCTAssertTrue(models.isEmpty, "Disabling fallback must hide Documents/Models entries")
    }

    // MARK: - Error reporting

    func test_discoverModels_reportingErrors_emitsNotGGUFForBadFile() throws {
        // Healthy file + corrupt file in the same primary directory.
        try writeMinimalGGUF(at: primaryDirectory.appendingPathComponent("good.gguf"))
        try Data(repeating: 0x00, count: 64)
            .write(to: primaryDirectory.appendingPathComponent("bad.gguf"))

        var reported: [ModelDiscoveryError] = []
        let models = service.discoverModels(reportingErrors: { reported.append($0) })

        XCTAssertEqual(models.count, 1, "Bad file must not abort the surrounding scan")
        XCTAssertEqual(models.first?.fileName, "good.gguf")
        XCTAssertEqual(reported.count, 1)
        if case .notGGUF(let path)? = reported.first {
            XCTAssertTrue(path.hasSuffix("bad.gguf"))
        } else {
            XCTFail("Expected .notGGUF for bad.gguf, got \(reported)")
        }
    }
}

// MARK: - Fixtures

private func makeScratchDirectory(named: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModelStorageFallbackTests-\(named)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeMinimalGGUF(at url: URL) throws {
    var data = Data([0x47, 0x47, 0x55, 0x46])
    appendUInt32(&data, 3)        // version
    appendUInt64(&data, 0)        // tensor count
    appendUInt64(&data, 0)        // KV count
    try data.write(to: url)
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func appendUInt64(_ data: inout Data, _ value: UInt64) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}
