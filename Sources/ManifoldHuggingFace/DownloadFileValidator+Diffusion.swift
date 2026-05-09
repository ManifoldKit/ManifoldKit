#if HuggingFace
import ManifoldInference
import Foundation
import os

extension DownloadFileValidator {

    /// The role a file plays inside a HuggingFace diffusers-layout snapshot.
    ///
    /// Each role has its own validation rules (JSON parse, safetensors header
    /// sanity, BPE merges-format heuristic). Schema validation of config
    /// contents — model dimensions, scheduler hyperparameters — is the
    /// loader's concern; the validator only catches obviously-corrupt or
    /// truncated files before the loader sees them.
    public enum DiffusionFileRole: Sendable {
        /// Top-level `model_index.json` listing the submodules present in the snapshot.
        case manifest
        /// A submodule's `config.json` (e.g. `unet/config.json`, `vae/config.json`).
        case submoduleConfig
        /// A `*.safetensors` weights file. Validated against the safetensors
        /// magic-bytes layout (8-byte little-endian header length).
        case weights
        /// A tokenizer's `vocab.json`.
        case tokenizerVocab
        /// A tokenizer's `merges.txt` (BPE merges file).
        case tokenizerMerges
    }

    /// Validates a single file in a diffusion-format snapshot.
    ///
    /// - Parameters:
    ///   - url: The downloaded file on disk.
    ///   - diffusionRole: What the file is supposed to be.
    ///   - expectedSize: When non-nil, asserts the on-disk size matches.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` on any failure.
    public static func validate(
        _ url: URL,
        diffusionRole: DiffusionFileRole,
        expectedSize: Int64? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Diffusion file does not exist at \(url.lastPathComponent)"
            )
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? Int64) ?? 0
        guard actualSize > 0 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Diffusion file is empty: \(url.lastPathComponent)"
            )
        }

        if let expectedSize, expectedSize > 0, actualSize != expectedSize {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Size mismatch for \(url.lastPathComponent): expected \(expectedSize), got \(actualSize)"
            )
        }

        switch diffusionRole {
        case .manifest, .submoduleConfig, .tokenizerVocab:
            try validateJSONFile(at: url)
        case .weights:
            try validateSafetensorsHeader(at: url, fileSize: actualSize)
        case .tokenizerMerges:
            try validateMergesFile(at: url)
        }

        Log.download.debug("Diffusion file validated: \(url.lastPathComponent, privacy: .public)")
    }

    // MARK: - JSON

    private static func validateJSONFile(at url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Cannot read JSON file \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "JSON parse failed for \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Safetensors

    /// Sanity-checks the 8-byte safetensors header.
    ///
    /// Safetensors layout: little-endian u64 header length, then UTF-8 JSON
    /// header of that length, then raw tensor bytes. A truncated download
    /// often parses fine as random data but produces a header length that
    /// would extend past EOF — that's the cheap check we do here.
    private static func validateSafetensorsHeader(at url: URL, fileSize: Int64) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Cannot open safetensors file: \(url.lastPathComponent)"
            )
        }
        defer { try? handle.close() }

        guard let headerLengthData = try? handle.read(upToCount: 8),
              headerLengthData.count == 8 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Safetensors file too small for header: \(url.lastPathComponent)"
            )
        }

        // Use `loadUnaligned` — `Data`'s underlying buffer has no alignment
        // guarantee, so a plain `load(as: UInt64.self)` can trap on hosts that
        // enforce alignment for 8-byte loads.
        let headerLength = headerLengthData.withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }.littleEndian

        // Plausibility: header must fit between the 8-byte prefix and EOF,
        // with at least 1 byte of tensor payload (margin avoids a degenerate
        // file claiming the entire body is header).
        guard headerLength > 0,
              headerLength < UInt64(fileSize) - 8 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Safetensors header length \(headerLength) is implausible for file size \(fileSize): \(url.lastPathComponent)"
            )
        }
    }

    // MARK: - Tokenizer merges

    /// Validates a BPE `merges.txt` file.
    ///
    /// HuggingFace BPE merges files conventionally start with a `#version: …`
    /// comment; we accept either that header or any non-empty first line so
    /// older fixtures still pass.
    private static func validateMergesFile(at url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Cannot read merges file \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Merges file is not UTF-8: \(url.lastPathComponent)"
            )
        }
        // Use `split(omittingEmptySubsequences: false)` so a leading newline
        // produces an empty first subsequence — which we explicitly reject.
        let firstLine = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .first.map(String.init) ?? ""
        guard !firstLine.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Merges file has empty first line: \(url.lastPathComponent)"
            )
        }
    }
}
#endif
