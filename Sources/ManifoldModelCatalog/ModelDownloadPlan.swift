import Foundation
import ManifoldHardware

/// Supported digest algorithms for model download verification.
public enum ModelFileChecksumAlgorithm: String, Sendable, Hashable, Codable {
    case sha256
}

/// Expected checksum for a downloaded model file.
public struct ModelFileChecksum: Sendable, Hashable, Codable {
    public let algorithm: ModelFileChecksumAlgorithm
    public let hexDigest: String

    public init(algorithm: ModelFileChecksumAlgorithm, hexDigest: String) {
        self.algorithm = algorithm
        self.hexDigest = hexDigest
    }
}

/// A single file that belongs to a model download.
public struct ModelDownloadFile: Sendable, Hashable, Codable {
    /// Relative path inside the model snapshot directory.
    public let relativePath: String
    /// Direct HuggingFace download URL for this file.
    public let url: URL
    /// Expected file size in bytes, when known.
    public let sizeBytes: UInt64
    /// Expected checksum for this file, when known.
    public let expectedChecksum: ModelFileChecksum?

    public init(
        relativePath: String,
        url: URL,
        sizeBytes: UInt64,
        expectedChecksum: ModelFileChecksum? = nil
    ) {
        self.relativePath = relativePath
        self.url = url
        self.sizeBytes = sizeBytes
        self.expectedChecksum = expectedChecksum
    }
}

/// The concrete download work needed for a `DownloadableModel`.
public enum ModelDownloadPlan: Sendable, Hashable {
    case singleFile(url: URL, expectedChecksum: ModelFileChecksum? = nil)
    case snapshot(files: [ModelDownloadFile])
}
