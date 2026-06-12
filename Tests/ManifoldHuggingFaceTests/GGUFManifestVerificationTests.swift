@preconcurrency import XCTest
import CryptoKit
@testable import ManifoldInference
@testable import ManifoldHuggingFace

// MARK: - Helpers

private struct AcceptingSignatureVerifier: GGUFSignedManifestSignatureVerifying {
    func verify(signature _: GGUFSignedManifest.Signature, canonicalPayload _: Data) throws -> Bool {
        true
    }
}

/// Unit tests for the sidecar GGUF manifest verification wired into
/// BackgroundDownloadManager's single-file download completion path.
///
/// These tests exercise `verifyGGUFManifestIfPresent(at:)` directly — they do
/// not create a real URLSession background task, so they are fast and deterministic.
@MainActor
final class GGUFManifestVerificationTests: XCTestCase {

    private var tempDirectory: URL!
    private var manager: BackgroundDownloadManager!
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GGUFManifestVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        suiteName = "com.manifoldkit.test.ggufmanifest.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!

        manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory),
            sessionIdentifier: "com.manifoldkit.test.ggufmanifest.\(UUID().uuidString)",
            userDefaults: testDefaults
        )
        // Inject an accepting signature verifier so tests can focus on digest
        // logic without tripping the fail-closed default signature policy.
        manager.ggufManifestVerifier = GGUFSignedManifestVerifier(
            signatureVerifier: AcceptingSignatureVerifier()
        )
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        tempDirectory = nil
        manager = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - No sidecar manifest

    func test_verifyGGUFManifestIfPresent_noManifest_passes() throws {
        let fileURL = tempDirectory.appendingPathComponent("model.gguf")
        try Data("fake gguf bytes".utf8).write(to: fileURL)
        // No manifest file alongside it — verification should succeed silently.
        XCTAssertNoThrow(try manager.verifyGGUFManifestIfPresent(at: fileURL))
    }

    // MARK: - Matching digest

    func test_verifyGGUFManifestIfPresent_matchingDigest_passes() throws {
        let content = Data("GGUF model weights".utf8)
        let fileURL = tempDirectory.appendingPathComponent("model.gguf")
        try content.write(to: fileURL)

        let manifest = makeManifest(path: "model.gguf", sha256: sha256Hex(content))
        let manifestURL = fileURL.appendingPathExtension("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        XCTAssertNoThrow(try manager.verifyGGUFManifestIfPresent(at: fileURL))
    }

    // MARK: - Digest mismatch → error

    func test_verifyGGUFManifestIfPresent_digestMismatch_throws() throws {
        let originalContent = Data("original weights".utf8)
        let tamperedContent = Data("tampered weights".utf8)

        let fileURL = tempDirectory.appendingPathComponent("model.gguf")
        // Write tampered bytes to the file but record the original digest in the manifest.
        try tamperedContent.write(to: fileURL)

        let manifest = makeManifest(path: "model.gguf", sha256: sha256Hex(originalContent))
        let manifestURL = fileURL.appendingPathExtension("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        XCTAssertThrowsError(try manager.verifyGGUFManifestIfPresent(at: fileURL)) { error in
            guard case GGUFSignedManifestVerificationError.digestMismatch(let path, _, _) = error else {
                XCTFail("Expected digestMismatch, got \(error)")
                return
            }
            XCTAssertEqual(path, "model.gguf")
        }
    }

    // MARK: - Manifest present but unsigned → error (fail-closed)

    func test_verifyGGUFManifestIfPresent_unsignedManifest_throws() throws {
        // Even with an accepting verifier, an *unsigned* manifest (nil signature)
        // must be rejected — the policy is fail-closed on unsigned input.
        let content = Data("GGUF model weights".utf8)
        let fileURL = tempDirectory.appendingPathComponent("model.gguf")
        try content.write(to: fileURL)

        let manifest = GGUFSignedManifest(
            payload: .init(files: [.init(path: "model.gguf", sha256: sha256Hex(content))]),
            signature: nil
        )
        let manifestURL = fileURL.appendingPathExtension("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        XCTAssertThrowsError(try manager.verifyGGUFManifestIfPresent(at: fileURL)) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .unsignedManifest)
        }
    }

    // MARK: - Helpers

    private func makeManifest(path: String, sha256: String) -> GGUFSignedManifest {
        GGUFSignedManifest(
            payload: .init(files: [.init(path: path, sha256: sha256)]),
            signature: .init(algorithm: "placeholder-ed25519", keyID: "test-key", value: "sig")
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
