import CryptoKit
import XCTest
@testable import ManifoldHardware

final class GGUFSignedManifestVerifierTests: XCTestCase {
    private struct AcceptingSignatureVerifier: GGUFSignedManifestSignatureVerifying {
        func verify(signature _: GGUFSignedManifest.Signature, canonicalPayload _: Data) throws -> Bool {
            true
        }
    }

    private struct RejectingSignatureVerifier: GGUFSignedManifestSignatureVerifying {
        func verify(signature _: GGUFSignedManifest.Signature, canonicalPayload _: Data) throws -> Bool {
            false
        }
    }

    private var scratchURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in scratchURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        scratchURLs.removeAll()
        try super.tearDownWithError()
    }

    func testVerify_acceptsSignedManifestWhenSHA256Matches() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "model.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))

        XCTAssertNoThrow(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        )
    }

    func testVerify_decodesManifestDataAndMatchesExpectedPath() throws {
        let fileURL = try makeScratchFile(name: "renamed.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "weights/model.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))
        let manifestData = try JSONEncoder().encode(manifest)

        XCTAssertNoThrow(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifestData: manifestData, expectedPath: "weights/model.gguf")
        )
    }

    func testVerify_failsClosedWhenManifestIsUnsigned() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = GGUFSignedManifest(
            payload: .init(files: [.init(path: "model.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))]),
            signature: nil
        )

        XCTAssertThrowsError(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        ) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .unsignedManifest)
        }
    }

    func testVerify_failsClosedWhenSignatureVerifierRejects() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "model.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))

        XCTAssertThrowsError(
            try GGUFSignedManifestVerifier(signatureVerifier: RejectingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        ) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .signatureRejected(keyID: "test-key"))
        }
    }

    func testVerify_rejectsDigestMismatch() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("tampered".utf8))
        let expected = sha256Hex(Data("original".utf8))
        let actual = sha256Hex(Data("tampered".utf8))
        let manifest = makeManifest(path: "model.gguf", sha256: expected)

        XCTAssertThrowsError(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? GGUFSignedManifestVerificationError,
                .digestMismatch(path: "model.gguf", expected: expected, actual: actual)
            )
        }
    }

    func testVerify_rejectsMalformedManifestSHA256() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "model.gguf", sha256: "not-a-sha")

        XCTAssertThrowsError(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        ) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .malformedSHA256(path: "model.gguf"))
        }
    }

    func testVerify_rejectsMissingManifestEntry() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "other.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))

        XCTAssertThrowsError(
            try GGUFSignedManifestVerifier(signatureVerifier: AcceptingSignatureVerifier())
                .verify(fileURL: fileURL, manifest: manifest)
        ) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .missingManifestEntry(path: "model.gguf"))
        }
    }

    func testDefaultSignatureVerifierRejectsUntilTrustPolicyIsInjected() throws {
        let fileURL = try makeScratchFile(name: "model.gguf", contents: Data("GGUF signed payload".utf8))
        let manifest = makeManifest(path: "model.gguf", sha256: sha256Hex(Data("GGUF signed payload".utf8)))

        XCTAssertThrowsError(try GGUFSignedManifestVerifier().verify(fileURL: fileURL, manifest: manifest)) { error in
            XCTAssertEqual(error as? GGUFSignedManifestVerificationError, .signatureRejected(keyID: "test-key"))
        }
    }

    private func makeManifest(path: String, sha256: String) -> GGUFSignedManifest {
        GGUFSignedManifest(
            payload: .init(files: [.init(path: path, sha256: sha256)]),
            signature: .init(algorithm: "placeholder-ed25519", keyID: "test-key", value: "signature")
        )
    }

    private func makeScratchFile(name: String, contents: Data) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("GGUFSignedManifestVerifierTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchURLs.append(root)
        let url = root.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
