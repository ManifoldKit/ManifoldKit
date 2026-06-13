import Foundation
import os

// Module-local logger — avoids importing ManifoldInference's `Log` enum
// so ManifoldHardware stays a zero-dependency leaf module.
private let logger = Logger(subsystem: "com.manifoldkit", category: "gguf")

/// Parsed metadata from a GGUF file header.
///
/// Contains the subset of GGUF metadata fields relevant to inference:
/// model name, architecture, context length, chat template, and file type (quantization).
package struct GGUFMetadata: Sendable, Equatable {
    package let generalName: String?
    package let generalArchitecture: String?
    package let contextLength: Int?
    package let chatTemplate: String?
    package let fileType: Int?
    package let kvCacheParameters: GGUFKVCacheParameters?

    package init(
        generalName: String?,
        generalArchitecture: String?,
        contextLength: Int?,
        chatTemplate: String?,
        fileType: Int?,
        kvCacheParameters: GGUFKVCacheParameters? = nil
    ) {
        self.generalName = generalName
        self.generalArchitecture = generalArchitecture
        self.contextLength = contextLength
        self.chatTemplate = chatTemplate
        self.fileType = fileType
        self.kvCacheParameters = kvCacheParameters
    }
}

/// Errors that can occur when reading GGUF metadata.
package enum GGUFReaderError: LocalizedError {
    case invalidMagic
    case unsupportedVersion(Int)
    case readError(String)

    package var errorDescription: String? {
        switch self {
        case .invalidMagic:
            "File is not a valid GGUF file (invalid magic bytes)"
        case .unsupportedVersion(let version):
            "Unsupported GGUF version: \(version) (expected 2 or 3)"
        case .readError(let detail):
            "Failed to read GGUF metadata: \(detail)"
        }
    }
}

/// Pure Swift binary parser that reads GGUF header metadata without loading the model.
///
/// Only reads the metadata key-value section at the start of the file. Tensor data
/// (which can be many gigabytes) is never touched. Uses `FileHandle` for sequential
/// reads to avoid loading the file into memory.
package struct GGUFMetadataReader {

    /// The four-byte magic at offset 0 of every GGUF file.
    private static let magicBytes: [UInt8] = [0x47, 0x47, 0x55, 0x46] // "GGUF"

    /// GGUF metadata value type codes.
    private enum ValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }

    // MARK: - Public API

    /// Reads metadata from a GGUF file header.
    ///
    /// Only reads the metadata section (before tensor data). The file handle is
    /// opened, read sequentially, and closed automatically.
    ///
    /// - Parameter url: Path to a `.gguf` file on disk.
    /// - Returns: Parsed metadata fields.
    /// - Throws: `GGUFReaderError` if the file is invalid or unreadable.
    package static func readMetadata(from url: URL) throws -> GGUFMetadata {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GGUFReaderError.readError("Cannot open file: \(error.localizedDescription)")
        }
        defer { handle.closeFile() }

        return try autoreleasepool {
            // why: previously each primitive read was one FileHandle.readData
            // syscall, and skipping a tokenizer vocab array meant one syscall per
            // element (128k–256k). A 64 KiB forward buffer collapses that to a
            // chunk read per refill; fixed-width arrays seek past in O(1) (#1787).
            let reader = BufferedFileReader(handle: handle)

            // Magic bytes (4 bytes)
            guard let magicData = reader.read(count: 4),
                  Array(magicData) == magicBytes else {
                throw GGUFReaderError.invalidMagic
            }

            // Version (uint32 LE)
            let version = try readUInt32(from: reader)
            guard version == 2 || version == 3 else {
                throw GGUFReaderError.unsupportedVersion(Int(version))
            }

            let isV3 = version == 3

            // Tensor count
            let _: UInt64 = isV3 ? try readUInt64(from: reader) : UInt64(try readUInt32(from: reader))

            // Metadata KV count
            let metadataCount: UInt64 = isV3 ? try readUInt64(from: reader) : UInt64(try readUInt32(from: reader))

            logger.debug("GGUF v\(version): \(metadataCount) metadata entries")

            // Keys we want to extract
            var generalName: String?
            var generalArchitecture: String?
            var contextLength: Int?
            var chatTemplate: String?
            var fileType: Int?
            var inferredArchitecture: String?
            var blockCount: Int?
            var embeddingLength: Int?
            var attentionHeadCount: Int?
            var attentionHeadCountKV: Int?
            var attentionKeyLength: Int?
            var attentionValueLength: Int?

            // Iterate KV pairs
            for _ in 0..<metadataCount {
                let key = try readString(from: reader)
                let valueTypeRaw = try readUInt32(from: reader)

                // Check if this is a key we care about
                switch key {
                case "general.name":
                    generalName = try readStringValue(type: valueTypeRaw, from: reader)

                case "general.architecture":
                    generalArchitecture = try readStringValue(type: valueTypeRaw, from: reader)
                    if inferredArchitecture == nil {
                        inferredArchitecture = generalArchitecture
                    }

                case "general.file_type":
                    fileType = try readIntegerValue(type: valueTypeRaw, from: reader)

                case "tokenizer.chat_template":
                    chatTemplate = try readStringValue(type: valueTypeRaw, from: reader)

                default:
                    let activeArchitecture = generalArchitecture ?? inferredArchitecture

                    if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".context_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        contextLength = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".block_count",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        blockCount = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".embedding_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        embeddingLength = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.head_count",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionHeadCount = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.head_count_kv",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionHeadCountKV = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.key_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionKeyLength = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.value_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionValueLength = try readIntegerValue(type: valueTypeRaw, from: reader)
                    } else {
                        try skipValue(type: valueTypeRaw, from: reader)
                    }
                }
            }

            logger.info(
                "GGUF metadata: name=\(generalName ?? "nil", privacy: .public), arch=\(generalArchitecture ?? "nil", privacy: .public), ctx=\(contextLength.map(String.init) ?? "nil", privacy: .public), template=\(chatTemplate != nil ? "present" : "nil", privacy: .public)"
            )

            return GGUFMetadata(
                generalName: generalName,
                generalArchitecture: generalArchitecture,
                contextLength: contextLength,
                chatTemplate: chatTemplate,
                fileType: fileType,
                kvCacheParameters: GGUFKVCacheParameters(
                    blockCount: blockCount,
                    embeddingLength: embeddingLength,
                    attentionHeadCount: attentionHeadCount,
                    attentionHeadCountKV: attentionHeadCountKV,
                    attentionKeyLength: attentionKeyLength,
                    attentionValueLength: attentionValueLength
                )
            )
        }
    }

    /// Validates that a file has valid GGUF magic bytes.
    ///
    /// - Parameter url: Path to check.
    /// - Returns: `true` if the first 4 bytes are the GGUF magic.
    package static func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }

        guard let data = readBytes(from: handle, count: 4) else { return false }
        return Array(data) == magicBytes
    }

    // MARK: - Primitive Readers

    /// One-shot 4-byte magic read used only by ``isValidGGUF(at:)`` — no buffered
    /// reader needed for a single read of a freshly-opened handle.
    private static func readBytes(from handle: FileHandle, count: Int) -> Data? {
        let data = handle.readData(ofLength: count)
        guard data.count == count else { return nil }
        return data
    }

    private static func readUInt8(from reader: BufferedFileReader) throws -> UInt8 {
        guard let data = reader.read(count: 1) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint8")
        }
        return data[data.startIndex]
    }

    private static func readUInt16(from reader: BufferedFileReader) throws -> UInt16 {
        guard let data = reader.read(count: 2) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint16")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    private static func readUInt32(from reader: BufferedFileReader) throws -> UInt32 {
        guard let data = reader.read(count: 4) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint32")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private static func readInt32(from reader: BufferedFileReader) throws -> Int32 {
        guard let data = reader.read(count: 4) else {
            throw GGUFReaderError.readError("Unexpected end of file reading int32")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
    }

    private static func readUInt64(from reader: BufferedFileReader) throws -> UInt64 {
        guard let data = reader.read(count: 8) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint64")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    private static func readInt64(from reader: BufferedFileReader) throws -> Int64 {
        guard let data = reader.read(count: 8) else {
            throw GGUFReaderError.readError("Unexpected end of file reading int64")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
    }

    /// Reads a GGUF string: uint64 length prefix followed by that many UTF-8 bytes.
    private static func readString(from reader: BufferedFileReader) throws -> String {
        let length = try readUInt64(from: reader)
        guard length <= 1_000_000 else {
            throw GGUFReaderError.readError("String length \(length) exceeds safety limit")
        }
        guard let data = reader.read(count: Int(length)) else {
            throw GGUFReaderError.readError("Unexpected end of file reading string of length \(length)")
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw GGUFReaderError.readError("Invalid UTF-8 in string of length \(length)")
        }
        return string
    }

    /// Skips a GGUF string (uint64 length + bytes) by SEEKING past the bytes
    /// instead of allocating + UTF-8-decoding them (the cost `readString` pays).
    /// Used when walking string arrays (`tokenizer.ggml.tokens` / `merges`),
    /// which carry no array-level byte count and so cannot be block-seeked (#1787).
    private static func skipString(from reader: BufferedFileReader) throws {
        let length = try readUInt64(from: reader)
        guard length <= 1_000_000 else {
            throw GGUFReaderError.readError("String length \(length) exceeds safety limit")
        }
        guard reader.skip(count: Int(length)) else {
            throw GGUFReaderError.readError("Unexpected end of file skipping string of length \(length)")
        }
    }

    // MARK: - Typed Value Readers

    /// Reads a value expected to be a STRING, returning it. Throws if wrong type.
    private static func readStringValue(type: UInt32, from reader: BufferedFileReader) throws -> String? {
        guard type == ValueType.string.rawValue else {
            try skipValue(type: type, from: reader)
            return nil
        }
        return try readString(from: reader)
    }

    /// Reads a scalar integer value, accepting signed or unsigned 32/64-bit GGUF integers.
    private static func readIntegerValue(type: UInt32, from reader: BufferedFileReader) throws -> Int? {
        switch ValueType(rawValue: type) {
        case .uint32:
            return Int(try readUInt32(from: reader))
        case .int32:
            return Int(try readInt32(from: reader))
        case .uint64:
            return Int(try readUInt64(from: reader))
        case .int64:
            return Int(try readInt64(from: reader))
        default:
            try skipValue(type: type, from: reader)
            return nil
        }
    }

    private static func matchingArchitecturePrefix(
        for key: String,
        suffix: String,
        expectedArchitecture: String?
    ) -> String? {
        guard key.hasSuffix(suffix) else { return nil }
        let prefix = String(key.dropLast(suffix.count))
        // GGUF architecture names are single identifiers (llama, phi, gemma, …).
        // Reject multi-component prefixes so keys like `general.custom.context_length`
        // don't poison inferredArchitecture with "general.custom".
        guard !prefix.isEmpty, !prefix.contains(".") else { return nil }
        guard expectedArchitecture == nil || expectedArchitecture == prefix else {
            return nil
        }
        return prefix
    }

    // MARK: - Value Skipping

    /// Maximum nesting depth for GGUF array values. Bounds `skipValue` recursion to
    /// prevent stack overflow from crafted files with deeply nested arrays.
    private static let maxArrayDepth = 32

    /// Maximum element count for a single GGUF array. Bounds the inner loop to
    /// prevent spin-loops from crafted files with huge declared array counts.
    ///
    /// Sized to comfortably accommodate the largest real tokenizer vocab arrays
    /// shipped with modern open-weight GGUFs:
    ///   - Llama 3:  ~128 256 tokens
    ///   - Gemma 2:  ~256 000 tokens
    ///   - Qwen 2/3: ~152 000 tokens
    ///
    /// The previous 65 536 ceiling rejected `tokenizer.ggml.tokens` /
    /// `tokenizer.ggml.scores` / `tokenizer.ggml.merges` on every one of those
    /// families and caused `ModelInfo(ggufURL:)` to silently drop prompt
    /// templates + context length + KV-cache estimates. See #1468.
    private static let maxArrayElementCount: UInt64 = 1_000_000

    /// Fixed byte width of a GGUF value type, or `nil` for variable-width types
    /// (string, array) that have no constant per-element size.
    private static func fixedWidth(of valueType: ValueType) -> Int? {
        switch valueType {
        case .uint8, .int8, .bool: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        case .string, .array: return nil
        }
    }

    /// Skips a value of the given type without parsing it.
    ///
    /// For arrays of FIXED-WIDTH elements (every numeric / bool type), the whole
    /// block is skipped with a single seek of `count * width` bytes (#1787) —
    /// this is the fast path for `tokenizer.ggml.scores` (f32) and `token_type`
    /// (i32). STRING arrays carry no array-level byte count (each element is
    /// `[uint64 len][len bytes]`), so they are walked element-by-element with
    /// ``skipString`` (length read + seek, no Data alloc / UTF-8 decode). Nested
    /// arrays recurse up to ``maxArrayDepth``.
    private static func skipValue(type: UInt32, from reader: BufferedFileReader, depth: Int = 0) throws {
        guard let valueType = ValueType(rawValue: type) else {
            throw GGUFReaderError.readError("Unknown value type: \(type)")
        }

        switch valueType {
        case .uint8, .int8, .bool:
            _ = try readUInt8(from: reader)

        case .uint16, .int16:
            _ = try readUInt16(from: reader)

        case .uint32, .int32, .float32:
            _ = try readUInt32(from: reader)

        case .uint64, .int64, .float64:
            _ = try readUInt64(from: reader)

        case .string:
            try skipString(from: reader)

        case .array:
            guard depth < maxArrayDepth else {
                throw GGUFReaderError.readError("Array nesting depth exceeds safety limit (\(maxArrayDepth))")
            }
            let elementTypeRaw = try readUInt32(from: reader)
            let count = try readUInt64(from: reader)
            guard count <= maxArrayElementCount else {
                throw GGUFReaderError.readError("Array element count \(count) exceeds safety limit (\(maxArrayElementCount))")
            }
            guard let elementType = ValueType(rawValue: elementTypeRaw) else {
                throw GGUFReaderError.readError("Unknown array element type: \(elementTypeRaw)")
            }

            // Fast path: a block of fixed-width elements is `count * width` bytes —
            // one seek instead of `count` per-element reads.
            if let width = fixedWidth(of: elementType) {
                let total = Int(count) * width
                guard reader.skip(count: total) else {
                    throw GGUFReaderError.readError("Unexpected end of file skipping \(count)-element array")
                }
                return
            }

            // String arrays: no array-level byte count — walk each element.
            if elementType == .string {
                for _ in 0..<count {
                    try skipString(from: reader)
                }
                return
            }

            // Nested arrays: recurse per element.
            for _ in 0..<count {
                try skipValue(type: elementTypeRaw, from: reader, depth: depth + 1)
            }
        }
    }
}

// MARK: - Buffered File Reader

/// A forward-only, fixed-size buffered reader over a `FileHandle`.
///
/// Serves the GGUF primitive reads from a 64 KiB window, refilling on underflow,
/// so reading the metadata region costs roughly one syscall per chunk instead of
/// one per primitive. ``skip(count:)`` seeks past data (used for fixed-width
/// arrays and skipped strings) and realigns the buffer.
///
/// Peak memory is one chunk plus one bounded primitive read — it never sizes the
/// buffer to the (unknown) metadata-region length.
private final class BufferedFileReader {
    private let handle: FileHandle
    private let chunkSize: Int
    /// The current buffer window. Bytes before `cursor` are already consumed.
    private var buffer = Data()
    private var cursor = 0
    /// Total file size, resolved once and reused to bounds-check forward seeks.
    private let fileSize: UInt64

    init(handle: FileHandle, chunkSize: Int = 64 * 1024) {
        self.handle = handle
        self.chunkSize = chunkSize
        var size: UInt64 = 0
        do {
            size = try handle.seekToEnd()
            // Rewind to the start so the first read sees the magic bytes.
            try handle.seek(toOffset: 0)
        } catch {
            // A handle that can't be sized/rewound yields fileSize 0; every
            // forward seek then fails its EOF bounds check and surfaces as a
            // readError to the caller rather than silently mis-parsing.
            logger.warning("BufferedFileReader: failed to size/rewind handle: \(error.localizedDescription, privacy: .public)")
        }
        self.fileSize = size
    }

    /// Bytes still available in the buffer without a refill.
    private var available: Int { buffer.count - cursor }

    /// Reads exactly `count` bytes, refilling the buffer as needed. Returns `nil`
    /// if the file ends before `count` bytes are available.
    func read(count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }

        // Fast path: fully satisfied from the current buffer.
        if available >= count {
            let start = buffer.index(buffer.startIndex, offsetBy: cursor)
            let end = buffer.index(start, offsetBy: count)
            cursor += count
            return Data(buffer[start..<end])
        }

        // Slow path: assemble across refills. Bounded by `count` (the caller's
        // primitive size or a length-prefixed string already capped at 1 MB).
        var result = Data(capacity: count)
        var remaining = count
        while remaining > 0 {
            if available == 0, !refill() { return nil }
            let take = min(available, remaining)
            let start = buffer.index(buffer.startIndex, offsetBy: cursor)
            let end = buffer.index(start, offsetBy: take)
            result.append(buffer[start..<end])
            cursor += take
            remaining -= take
        }
        return result
    }

    /// Skips `count` bytes. Consumes any buffered bytes first, then seeks the
    /// underlying handle past the remainder and drops the (now-stale) buffer so
    /// the next read realigns. Returns `false` if the file ends early.
    func skip(count: Int) -> Bool {
        guard count >= 0 else { return false }
        if count == 0 { return true }

        let fromBuffer = min(available, count)
        cursor += fromBuffer
        let remaining = count - fromBuffer
        if remaining == 0 { return true }

        // The buffer is now fully consumed, so the handle's physical offset is the
        // logical next byte. Seek forward past the remainder and drop the buffer.
        do {
            let currentOffset = try handle.offset()
            let target = currentOffset + UInt64(remaining)
            // Guard against seeking past EOF, which FileHandle silently allows —
            // a subsequent read would then return short and surface as a readError.
            guard target <= fileSize else {
                buffer = Data()
                cursor = 0
                return false
            }
            try handle.seek(toOffset: target)
        } catch {
            logger.warning("BufferedFileReader: seek failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        buffer = Data()
        cursor = 0
        return true
    }

    /// Refills the buffer with the next chunk. Returns `false` at EOF.
    private func refill() -> Bool {
        let next: Data
        do {
            next = try handle.read(upToCount: chunkSize) ?? Data()
        } catch {
            return false
        }
        guard !next.isEmpty else { return false }
        buffer = next
        cursor = 0
        return true
    }
}
