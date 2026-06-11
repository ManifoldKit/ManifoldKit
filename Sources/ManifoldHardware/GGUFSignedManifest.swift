import CryptoKit
import Foundation

/// Detached, signed manifest describing GGUF weight digests.
///
/// The verifier below deliberately makes signature enforcement an injected seam:
/// ManifoldKit can fail closed for unsigned/rejected manifests now, while a future
/// trust-chain implementation owns key discovery and cryptographic policy.
public struct GGUFSignedManifest: Codable, Hashable, Sendable {
    public struct Payload: Codable, Hashable, Sendable {
        public let files: [File]

        public init(files: [File]) {
            self.files = files
        }
    }

    public struct File: Codable, Hashable, Sendable {
        public let path: String
        public let sha256: String

        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }
    }

    public struct Signature: Codable, Hashable, Sendable {
        public let algorithm: String
        public let keyID: String
        public let value: String

        public init(algorithm: String, keyID: String, value: String) {
            self.algorithm = algorithm
            self.keyID = keyID
            self.value = value
        }
    }

    public let payload: Payload
    public let signature: Signature?

    public init(payload: Payload, signature: Signature?) {
        self.payload = payload
        self.signature = signature
    }
}

/// Signature policy injected into ``GGUFSignedManifestVerifier``.
public protocol GGUFSignedManifestSignatureVerifying: Sendable {
    /// Return `true` only when `canonicalPayload` is authenticated by `signature`.
    func verify(signature: GGUFSignedManifest.Signature, canonicalPayload: Data) throws -> Bool
}

/// Explicit fail-closed placeholder used until product trust-chain policy exists.
public struct RejectingGGUFSignedManifestSignatureVerifier: GGUFSignedManifestSignatureVerifying {
    public init() {}

    public func verify(signature _: GGUFSignedManifest.Signature, canonicalPayload _: Data) throws -> Bool {
        false
    }
}

public enum GGUFSignedManifestVerificationError: LocalizedError, Equatable {
    case unsignedManifest
    case signatureRejected(keyID: String)
    case malformedSHA256(path: String)
    case missingManifestEntry(path: String)
    case fileMissing(path: String)
    case digestMismatch(path: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unsignedManifest:
            return "GGUF manifest is unsigned."
        case .signatureRejected(let keyID):
            return "GGUF manifest signature was rejected for key '\(keyID)'."
        case .malformedSHA256(let path):
            return "GGUF manifest entry for '\(path)' has a malformed SHA-256 digest."
        case .missingManifestEntry(let path):
            return "GGUF manifest does not contain an entry for '\(path)'."
        case .fileMissing(let path):
            return "GGUF file for manifest verification is missing at '\(path)'."
        case .digestMismatch(let path, let expected, let actual):
            return "GGUF SHA-256 mismatch for '\(path)': expected \(expected), got \(actual)."
        }
    }
}

/// Opt-in verifier for GGUF files described by a signed SHA-256 manifest.
public struct GGUFSignedManifestVerifier: Sendable {
    private let signatureVerifier: any GGUFSignedManifestSignatureVerifying

    public init(signatureVerifier: any GGUFSignedManifestSignatureVerifying = RejectingGGUFSignedManifestSignatureVerifier()) {
        self.signatureVerifier = signatureVerifier
    }

    /// Decodes and verifies `fileURL` against `manifestData`.
    ///
    /// - Parameters:
    ///   - expectedPath: Relative manifest path to match. Defaults to the file's last path component.
    /// - Throws: ``GGUFSignedManifestVerificationError`` when the manifest is unsigned,
    ///   the signature verifier rejects it, the manifest entry is malformed/missing,
    ///   or the file digest does not match.
    public func verify(fileURL: URL, manifestData: Data, expectedPath: String? = nil) throws {
        let manifest = try JSONDecoder().decode(GGUFSignedManifest.self, from: manifestData)
        try verify(fileURL: fileURL, manifest: manifest, expectedPath: expectedPath)
    }

    public func verify(fileURL: URL, manifest: GGUFSignedManifest, expectedPath: String? = nil) throws {
        try requireAcceptedSignature(for: manifest)

        let path = expectedPath ?? fileURL.lastPathComponent
        guard let entry = manifest.payload.files.first(where: { $0.path == path }) else {
            throw GGUFSignedManifestVerificationError.missingManifestEntry(path: path)
        }

        let expected = entry.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw GGUFSignedManifestVerificationError.malformedSHA256(path: entry.path)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GGUFSignedManifestVerificationError.fileMissing(path: fileURL.path)
        }

        let actual = try sha256HexDigest(of: fileURL)
        guard actual == expected else {
            throw GGUFSignedManifestVerificationError.digestMismatch(
                path: entry.path,
                expected: expected,
                actual: actual
            )
        }
    }

    @discardableResult
    private func requireAcceptedSignature(for manifest: GGUFSignedManifest) throws -> GGUFSignedManifest.Signature {
        guard let signature = manifest.signature else {
            throw GGUFSignedManifestVerificationError.unsignedManifest
        }
        let canonicalPayload = try Self.canonicalPayloadData(for: manifest.payload)
        guard try signatureVerifier.verify(signature: signature, canonicalPayload: canonicalPayload) else {
            throw GGUFSignedManifestVerificationError.signatureRejected(keyID: signature.keyID)
        }
        return signature
    }

    public static func canonicalPayloadData(for payload: GGUFSignedManifest.Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private func sha256HexDigest(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
