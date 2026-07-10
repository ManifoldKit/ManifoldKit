import ManifoldInference
import CryptoKit
import Foundation
import os

/// Validates downloaded model files for format correctness.
///
/// Checks GGUF magic bytes and file size for GGUF models; verifies directory
/// structure (config.json + .safetensors) for MLX snapshot downloads.
/// All methods are pure: they take a URL and throw — no instance state required.
public struct DownloadFileValidator {

    /// Public initializer so external callers (e.g. `ManifoldRuntime`) can
    /// construct the validator. The type carries no instance state today,
    /// but keeping a memberwise init reserved to package code preserved
    /// flexibility to add some.
    public init() {}

    /// GGUF magic bytes: "GGUF" in ASCII (0x47, 0x47, 0x55, 0x46).
    private static let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

    /// Validates that a downloaded file has the correct format for its model type.
    ///
    /// - Parameters:
    ///   - fileURL: The file or directory to validate.
    ///   - modelType: The expected model type.
    ///   - expectedChecksum: Expected digest to enforce when available.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` if validation fails.
    func validate(at fileURL: URL, modelType: ModelType, expectedChecksum: ModelFileChecksum? = nil) throws {
        switch modelType {
        case .gguf:
            try validateGGUFFile(at: fileURL)
        case .mlx:
            try validateMLXDirectory(at: fileURL)
        case .foundation:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Foundation models cannot be downloaded")
        default:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Unsupported model type '\(modelType.rawValue)' — no download validator is registered for it")
        }
        try validateChecksum(at: fileURL, expectedChecksum: expectedChecksum)
    }

    // MARK: - GGUF

    private func validateGGUFFile(at fileURL: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Cannot open downloaded GGUF file")
        }
        defer { handle.closeFile() }

        guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "GGUF file too small — expected at least 4 bytes"
            )
        }

        let bytes = [UInt8](headerData)
        guard bytes == Self.ggufMagic else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Invalid GGUF magic bytes: expected [47,47,55,46], got \(bytes)"
            )
        }

        // Verify file size is reasonable — a truncated file with correct magic would pass above.
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        guard fileSize > 1_000_000 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Downloaded file is too small (\(fileSize) bytes) — likely corrupted or incomplete"
            )
        }

        Log.download.debug("GGUF file validated successfully at \(fileURL.lastPathComponent)")
    }

    // MARK: - MLX

    private func validateMLXDirectory(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Downloaded MLX file does not exist")
        }
        // MLX models must be directories containing config.json + .safetensors files.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // A single file is not a valid MLX model — likely an HTML error page
            // from trying to download a directory URL.
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "MLX models require snapshot download (multiple files). Single-file download is not supported."
            )
        }
        let configPath = fileURL.appendingPathComponent("config.json").path
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "MLX model directory is missing config.json")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: fileURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "MLX model directory could not be enumerated")
        }
        let hasSafetensors = enumerator
            .compactMap { $0 as? URL }
            .contains { $0.pathExtension.lowercased() == "safetensors" }
        guard hasSafetensors else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "MLX model directory contains no .safetensors files")
        }
    }

    // MARK: - Checksum

    func validateChecksum(at fileURL: URL, expectedChecksum: ModelFileChecksum?) throws {
        guard let expectedChecksum else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Downloaded file for checksum validation does not exist")
        }

        switch expectedChecksum.algorithm {
        case .sha256:
            let expected = expectedChecksum.hexDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Expected SHA-256 checksum is malformed")
            }

            let actual = try sha256HexDigest(of: fileURL)
            guard actual == expected else {
                throw HuggingFaceError.invalidDownloadedFile(
                    reason: "Checksum mismatch for \(fileURL.lastPathComponent): expected SHA-256 \(expected), got \(actual)"
                )
            }
        }
    }

    private func sha256HexDigest(of fileURL: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Cannot open downloaded file for checksum validation")
        }
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
