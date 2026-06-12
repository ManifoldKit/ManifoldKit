import XCTest
@testable import ManifoldHuggingFace

/// Unit coverage for ``DownloadedFileProtection``.
///
/// The kernel Data Protection attribute (`NSFileProtection*`) is an iOS-only
/// feature; the macOS `swift test` lane exercises the no-op path. The on-disk
/// assertion that the attribute is actually applied lives in the iOS-Simulator
/// lane (`scripts/test-ios-simulator.sh`, mirroring
/// `ModelContainerFileProtectionTests`). Here we pin the contract that matters
/// on every platform: `protect` is best-effort and must never throw or mutate
/// the file's contents, so it can be called inline on the download completion
/// path without risk of failing a finished download.
final class DownloadedFileProtectionTests: XCTestCase {

    func test_protect_doesNotThrowOrCorruptFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfp-\(UUID().uuidString).bin")
        let payload = Data("model-weights".utf8)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Best-effort: returns normally on every platform (no-op on macOS).
        DownloadedFileProtection.protect(tmp)

        XCTAssertEqual(try Data(contentsOf: tmp), payload,
                       "protect must never alter the file's contents")
    }

    func test_protect_missingFile_isHarmless() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfp-missing-\(UUID().uuidString).bin")
        // Applying protection to a nonexistent path must be a silent no-op,
        // never a crash or thrown error.
        DownloadedFileProtection.protect(absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
}
