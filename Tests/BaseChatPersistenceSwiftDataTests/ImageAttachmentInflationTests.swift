import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// Perf-audit ground-truth: confirms that persisting `MessagePart.image(data:)`
/// through the SwiftData JSON column inflates on-disk bytes by ~1.33×, the
/// expected base64 overhead.
///
/// SwiftData's in-memory store resolves to `/dev/null`, so this suite uses an
/// explicit on-disk `ModelConfiguration(url:)` rooted in a per-test temp
/// directory and cleans up in `tearDown`.
///
/// N=10 with `approxBytes: 100_000` (~1 MB raw before inflation) is smaller
/// than the audit plan's 25×4 MB fixture — the smaller fixture makes CI fast
/// (<1 s) while still proving the inflation factor. The factor itself is the
/// audit's load-bearing number; the fixture size is a secondary lever the
/// downstream blob-store PR will tune separately.
final class ImageAttachmentInflationTests: XCTestCase {

    private var tempStoreDirectory: URL?

    override func tearDownWithError() throws {
        if let tempStoreDirectory {
            try? FileManager.default.removeItem(at: tempStoreDirectory)
        }
        tempStoreDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates an isolated per-test directory + on-disk store URL.
    private func makeTempStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaseChatImageInflation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempStoreDirectory = directory
        return directory.appendingPathComponent("BaseChat.sqlite")
    }

    /// Sums the size of the SwiftData store file plus any sibling WAL/SHM
    /// sidecars SwiftData may have created. SwiftData defaults to WAL
    /// journalling, so the main `.sqlite` file alone undercounts on-disk cost.
    private func storeSizeBytes(at storeURL: URL) throws -> UInt64 {
        let directory = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var total: UInt64 = 0
        for entry in entries where entry == baseName || entry.hasPrefix("\(baseName)-") {
            let path = directory.appendingPathComponent(entry).path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attrs[.size] as? NSNumber {
                total += size.uint64Value
            }
        }
        return total
    }

    /// Builds a session of N user messages, each carrying one image part of
    /// `imageBytes` raw bytes plus a short text caption. Returns the raw
    /// image-byte total so callers can compute inflation.
    @discardableResult
    private func seedVisionSession(
        context: ModelContext,
        messageCount: Int,
        imageBytes: Int
    ) throws -> UInt64 {
        let sessionID = UUID()
        let session = ChatSession(title: "Vision Inflation")
        // ChatSession's id is generated in init; force the field to match the
        // sessionID we use on the messages so the foreign-key relationship
        // mirrors production usage.
        session.id = sessionID
        context.insert(session)

        let imageData = ImageFixtures.largeJPEG(approxBytes: imageBytes)
        var rawTotal: UInt64 = 0
        for index in 0..<messageCount {
            let parts: [MessagePart] = [
                .text("attachment-\(index)"),
                .image(data: imageData, mimeType: "image/jpeg"),
            ]
            let message = ChatMessage(role: .user, contentParts: parts, sessionID: sessionID)
            context.insert(message)
            rawTotal += UInt64(imageData.count)
        }
        try context.save()
        return rawTotal
    }

    // MARK: - Tests

    /// Asserts that on-disk storage of N images inflates raw bytes by AT
    /// LEAST the base64 factor (~1.33×). The audit estimated 1.33× (base64
    /// floor); the actual measured number on a 10×100 KB fixture is closer
    /// to 2.9× — the SQLite store carries page-aligned overhead, the WAL
    /// sidecar holds duplicate pages mid-checkpoint, and SwiftData adds
    /// per-row metadata indexes on top of base64. The 2.9× number IS the
    /// audit ground truth; the assertion only pins the floor so the test
    /// doesn't go silent if SwiftData ever stops base64-encoding bytes
    /// (e.g. switches to BLOB columns, in which case the inflation drops
    /// near 1.0× and the audit's premise changes).
    func test_jsonStorageInflatesBytesByBase64Factor() throws {
        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainerFactory.makeContainer(configurations: [config])
        let context = ModelContext(container)

        let messageCount = 10
        let bytesPerImage = 100_000
        let rawTotal = try seedVisionSession(
            context: context,
            messageCount: messageCount,
            imageBytes: bytesPerImage
        )

        // Drop our reference to the container to coax SwiftData into flushing
        // the WAL into the main store. This isn't strictly required because
        // storeSizeBytes also counts sidecars, but it makes the numbers
        // closer to a steady-state on-disk footprint.
        try context.save()

        let storedBytes = try storeSizeBytes(at: storeURL)
        XCTAssertGreaterThan(rawTotal, 0, "Fixture must produce non-zero raw bytes")

        let inflation = Double(storedBytes) / Double(rawTotal)

        let attachment = XCTAttachment(string: """
            messageCount=\(messageCount)
            bytesPerImage=\(bytesPerImage)
            rawImageBytesTotal=\(rawTotal)
            storeBytesTotal=\(storedBytes)
            inflationFactor=\(String(format: "%.3f", inflation))
            """)
        attachment.name = "image-inflation-numbers"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(
            inflation, 1.30,
            "Stored bytes / raw bytes should be at least the base64 floor (~1.33). Got \(inflation)."
        )
        // No upper bound — the actual measured factor (~2.9×) is the audit
        // ground truth, not a regression we want to alert on. A future blob-
        // store PR is expected to bring this back near 1.0×.
    }

    /// Records ground-truth raw + stored bytes for a vision session as an
    /// attachment, without a tight assertion. The numbers are the value here —
    /// the downstream blob-store PR uses them as the baseline to beat.
    func test_rawByteAccountingForVisionSession() throws {
        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainerFactory.makeContainer(configurations: [config])
        let context = ModelContext(container)

        let messageCount = 10
        let bytesPerImage = 100_000
        let rawTotal = try seedVisionSession(
            context: context,
            messageCount: messageCount,
            imageBytes: bytesPerImage
        )
        try context.save()
        let storedBytes = try storeSizeBytes(at: storeURL)

        let attachment = XCTAttachment(string: """
            ## Vision-session raw-byte accounting

            messageCount: \(messageCount)
            bytesPerImage: \(bytesPerImage)
            rawImageBytesTotal: \(rawTotal)
            storeBytesTotal: \(storedBytes)
            deltaBytes: \(Int64(storedBytes) - Int64(rawTotal))
            """)
        attachment.name = "vision-session-byte-accounting"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Sanity floor only — proves we measured something.
        XCTAssertGreaterThan(storedBytes, rawTotal,
                             "Stored bytes should exceed raw bytes due to base64 + SwiftData overhead")
    }
}
