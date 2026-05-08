@preconcurrency import XCTest
@testable import BaseChatInference
#if HuggingFace
@testable import BaseChatHuggingFace

/// Integrity tests for the HMAC-tagged resume blob.
///
/// `consumeResumeData(for:)` must fail closed when the blob has been
/// tampered with on disk — the alternative is feeding corrupted bytes
/// into `URLSession.downloadTask(withResumeData:)`, which has historically
/// crashed on certain `.cfd`-shaped inputs.
@MainActor
final class BackgroundDownloadManagerHMACTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!
    private var persistenceDir: URL!
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HMACTests-\(UUID().uuidString)")
        persistenceDir = tempDirectory.appendingPathComponent("persistence")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        suiteName = "com.basechatkit.test.hmac.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!

        manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory),
            sessionIdentifier: "com.basechatkit.test.hmac.\(UUID().uuidString)",
            persistenceDirectory: persistenceDir,
            userDefaults: testDefaults
        )
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        // Reset the per-process key cache so a flipped key in a later test
        // doesn't carry over.
        BackgroundDownloadManager._resetResumeHMACKeyCacheForTesting()
        manager = nil
        tempDirectory = nil
        persistenceDir = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Roundtrip

    func test_persistAndConsume_roundtripPreservesData() {
        let id = "model-roundtrip-\(UUID().uuidString)"
        let payload = Data("resume-payload-\(UUID().uuidString)".utf8)

        manager.persistResumeData(payload, for: id)
        let consumed = manager.consumeResumeData(for: id)
        XCTAssertEqual(consumed, payload, "persist → consume must return the original bytes")
    }

    func test_persist_writesBlobAndTagFiles() {
        let id = "model-files-\(UUID().uuidString)"
        let payload = Data("payload".utf8)
        manager.persistResumeData(payload, for: id)

        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let blobURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin")
        let tagURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin.tag")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path), "blob file must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tagURL.path), "tag file must exist")

        // Tag must be 32 bytes (HMAC-SHA256 output).
        let tagBytes = try? Data(contentsOf: tagURL)
        XCTAssertEqual(tagBytes?.count, 32, "HMAC-SHA256 tag is 32 bytes")
    }

    // MARK: - Tamper detection (the threat model)

    func test_consume_rejectsBlobWithFlippedByte() throws {
        let id = "model-tamper-\(UUID().uuidString)"
        let payload = Data("untampered".utf8)
        manager.persistResumeData(payload, for: id)

        // Flip the first byte of the blob.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let blobURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin")
        var bytes = try Data(contentsOf: blobURL)
        bytes[0] ^= 0xFF
        try bytes.write(to: blobURL, options: .atomic)

        let consumed = manager.consumeResumeData(for: id)
        XCTAssertNil(consumed, "Tampered blob must fail closed and return nil")

        // Both files must be removed so the next attempt starts fresh.
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path),
                       "Tampered blob file must be deleted")
        let tagURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin.tag")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tagURL.path),
                       "Stale tag file must be deleted alongside the rejected blob")
    }

    func test_consume_rejectsBlobWithMissingTag() throws {
        let id = "model-notag-\(UUID().uuidString)"
        let payload = Data("untagged".utf8)
        manager.persistResumeData(payload, for: id)

        // Delete the tag file out from under the read.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let tagURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin.tag")
        try FileManager.default.removeItem(at: tagURL)

        let consumed = manager.consumeResumeData(for: id)
        XCTAssertNil(consumed, "Missing tag must fail closed")
    }

    func test_consume_rejectsBlobWithFlippedTag() throws {
        let id = "model-flippedtag-\(UUID().uuidString)"
        let payload = Data("payload".utf8)
        manager.persistResumeData(payload, for: id)

        // Flip a byte in the tag.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let tagURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin.tag")
        var tag = try Data(contentsOf: tagURL)
        tag[10] ^= 0x80
        try tag.write(to: tagURL, options: .atomic)

        let consumed = manager.consumeResumeData(for: id)
        XCTAssertNil(consumed, "Flipped tag byte must fail closed")
    }

    // MARK: - Tag computation

    func test_computeTag_isDeterministicForSameKey() throws {
        let payload = Data("deterministic-payload".utf8)
        let tag1 = try BackgroundDownloadManager.computeResumeHMACTag(for: payload)
        let tag2 = try BackgroundDownloadManager.computeResumeHMACTag(for: payload)
        XCTAssertEqual(tag1, tag2, "Two computations against the same key must produce the same tag")
        XCTAssertEqual(tag1.count, 32)
    }

    func test_constantTimeEqual_matchesData() {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x01, 0x02, 0x03, 0x04])
        let c = Data([0x01, 0x02, 0x03, 0x05])
        let d = Data([0x01, 0x02, 0x03])
        XCTAssertTrue(BackgroundDownloadManager.constantTimeEqual(a, b))
        XCTAssertFalse(BackgroundDownloadManager.constantTimeEqual(a, c))
        XCTAssertFalse(BackgroundDownloadManager.constantTimeEqual(a, d))
    }
}

#endif
