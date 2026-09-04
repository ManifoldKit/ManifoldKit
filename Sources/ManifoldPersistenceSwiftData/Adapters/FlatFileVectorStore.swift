import Foundation
import ManifoldInference
import ManifoldRuntime

// MARK: - FlatFileVectorStore

/// ``VectorStore`` backed by a compact binary file loaded fully into memory.
///
/// Correct for libraries up to ~50 000 chunks. Search is O(n) cosine
/// similarity over L2-normalized embeddings (dot-product after normalization).
/// The entire index is rewritten on each mutation — acceptable for the write
/// patterns of a local document library (ingest once, query many times).
///
/// Only a missing index starts as an empty store. Existing indexes that cannot
/// be read or decoded propagate their error and are never replaced implicitly.
///
/// File format: 20-byte header followed by variable-length records. See the
/// private `encode`/`decode` helpers for the exact byte layout.
public actor FlatFileVectorStore: VectorStore {

    // MARK: - In-memory model

    private struct Record: Sendable {
        var chunkID: UUID
        var documentID: UUID
        var chunkIndex: Int32
        /// L2-normalized; empty when ingested without an embedding model.
        var embedding: [Float]
        var documentTitle: String
        var text: String
    }

    // MARK: - State

    private let storageURL: URL
    /// Kept narrow so concrete-store tests can force a real file write to fail
    /// without replacing the persistence implementation.
    private let fileWriter: @Sendable (Data, URL) throws -> Void
    /// Nil until the first access; loaded lazily.
    private var records: [Record]?

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.fileWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// Internal test seam for one concrete file-write failure path. Successful
    /// writes must still write `data` to `url`; this does not replace storage.
    init(
        storageURL: URL,
        fileWriter: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.storageURL = storageURL
        self.fileWriter = fileWriter
    }

    // MARK: - VectorStore

    public func insert(
        chunks: [DocumentChunk],
        documentTitle: String,
        embeddings: [[Float]]
    ) throws {
        var loaded = try ensureLoaded()

        for (i, chunk) in chunks.enumerated() {
            let rawEmbedding = i < embeddings.count ? embeddings[i] : []
            let normalized = rawEmbedding.isEmpty ? [] : l2normalize(rawEmbedding)
            loaded.append(Record(
                chunkID: chunk.id,
                documentID: chunk.documentID,
                chunkIndex: Int32(chunk.chunkIndex),
                embedding: normalized,
                documentTitle: documentTitle,
                text: chunk.text
            ))
        }

        try persist(loaded)
        records = loaded
    }

    public func search(embedding: [Float], limit: Int) throws -> [VectorSearchHit] {
        let loaded = try ensureLoaded()
        let query = l2normalize(embedding)
        guard !query.isEmpty else { return [] }

        let scored: [(record: Record, score: Float)] = loaded.compactMap { record in
            guard record.embedding.count == query.count else { return nil }
            let score = dotProduct(query, record.embedding)
            return (record, score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { pair in
                VectorSearchHit(
                    chunk: DocumentChunk(
                        id: pair.record.chunkID,
                        documentID: pair.record.documentID,
                        text: pair.record.text,
                        chunkIndex: Int(pair.record.chunkIndex)
                    ),
                    documentTitle: pair.record.documentTitle,
                    score: pair.score
                )
            }
    }

    public func keywordSearch(query: String, limit: Int) throws -> [VectorSearchHit] {
        let loaded = try ensureLoaded()
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()

        return loaded
            .filter { $0.text.lowercased().contains(lower) }
            .prefix(limit)
            .map { record in
                VectorSearchHit(
                    chunk: DocumentChunk(
                        id: record.chunkID,
                        documentID: record.documentID,
                        text: record.text,
                        chunkIndex: Int(record.chunkIndex)
                    ),
                    documentTitle: record.documentTitle,
                    score: 1.0
                )
            }
    }

    /// Sparse BM25 ranking over the in-memory corpus (#1919).
    ///
    /// Builds a `BM25Scorer` from the loaded records on each call. For the
    /// flat-file store's documented ceiling (~50k chunks, already fully resident)
    /// this is acceptable: the index is recomputed rather than persisted, which
    /// avoids a SwiftData schema migration for a postings table while still
    /// giving real term-frequency · IDF · length-normalized scoring. The legacy
    /// ``keywordSearch`` stays as the no-embedding fallback; this method powers
    /// the sparse leg of hybrid retrieval.
    public func bm25Search(query: String, limit: Int) async throws -> [VectorSearchHit] {
        let loaded = try ensureLoaded()
        guard !query.isEmpty, limit > 0 else { return [] }

        let scorer = BM25Scorer(corpus: loaded.map { ($0.chunkID, $0.text) })
        let ranked = scorer.score(query: query, limit: limit)

        // Map scored chunk IDs back to records. Build a lookup once so the join
        // is O(n) rather than O(n·k).
        let byID = Dictionary(loaded.map { ($0.chunkID, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { result in
            guard let record = byID[result.id] else { return nil }
            return VectorSearchHit(
                chunk: DocumentChunk(
                    id: record.chunkID,
                    documentID: record.documentID,
                    text: record.text,
                    chunkIndex: Int(record.chunkIndex)
                ),
                documentTitle: record.documentTitle,
                // BM25 scores are unbounded; carry the raw value through so
                // RRF (which fuses on rank, not magnitude) and any downstream
                // inspection see the real sparse signal.
                score: Float(result.score)
            )
        }
    }

    public func delete(documentID: UUID) throws {
        var loaded = try ensureLoaded()
        loaded.removeAll { $0.documentID == documentID }
        try persist(loaded)
        records = loaded
    }

    public func deleteAll() throws {
        try persist([])
        records = []
    }

    // MARK: - Persistence

    private func ensureLoaded() throws -> [Record] {
        if let cached = records { return cached }
        let loaded = try load()
        records = loaded
        return loaded
    }

    private func load() throws -> [Record] {
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            let nsError = error as NSError
            let isMissingIndex = nsError.domain == NSCocoaErrorDomain && (
                nsError.code == CocoaError.Code.fileNoSuchFile.rawValue ||
                nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
            )
            if isMissingIndex {
                return []
            }
            let name = self.storageURL.lastPathComponent
            Log.persistence.warning("FlatFileVectorStore: failed to read \(name, privacy: .public): \(error.localizedDescription)")
            throw error
        }
        do {
            return try decode(data)
        } catch {
            Log.persistence.warning("FlatFileVectorStore: invalid index: \(error.localizedDescription)")
            throw error
        }
    }

    private func persist(_ records: [Record]) throws {
        let data = encode(records)
        do {
            try fileWriter(data, storageURL)
        } catch {
            throw VectorStoreError.writeFailed(underlying: error)
        }
    }

    // MARK: - Binary encoding

    private static let magic: [UInt8] = [0x42, 0x43, 0x4B, 0x56]  // "BCKV"
    private static let version: UInt8 = 1

    private func encode(_ records: [Record]) -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.append(Self.version)
        data.append(contentsOf: [0x00, 0x00, 0x00])  // pad
        data.appendUInt32(UInt32(records.count))
        data.appendUInt32(0)  // dims field reserved

        for record in records {
            data.appendUUID(record.chunkID)
            data.appendUUID(record.documentID)
            data.appendInt32(record.chunkIndex)
            data.appendUInt32(UInt32(record.embedding.count))
            record.embedding.forEach { data.appendFloat($0) }
            data.appendLengthPrefixedUTF8(record.documentTitle)
            data.appendLengthPrefixedUTF8(record.text)
        }

        return data
    }

    private func decode(_ data: Data) throws -> [Record] {
        var cursor = DataCursor(data: data)

        let magic = try cursor.readBytes(4)
        guard magic == Self.magic else { throw VectorStoreError.invalidFormat }
        let version = try cursor.readByte()
        guard version == Self.version else { throw VectorStoreError.unsupportedVersion(version) }
        try cursor.skip(3)
        let count = try cursor.readUInt32()
        try cursor.skip(4)  // dims (reserved)

        var records: [Record] = []
        records.reserveCapacity(Int(count))

        for _ in 0..<count {
            let chunkID = try cursor.readUUID()
            let documentID = try cursor.readUUID()
            let chunkIndex = try cursor.readInt32()
            let embedLen = Int(try cursor.readUInt32())
            let embedding = try cursor.readFloats(count: embedLen)
            let title = try cursor.readLengthPrefixedUTF8()
            let text = try cursor.readLengthPrefixedUTF8()

            records.append(Record(
                chunkID: chunkID,
                documentID: documentID,
                chunkIndex: chunkIndex,
                embedding: embedding,
                documentTitle: title,
                text: text
            ))
        }

        return records
    }

    // MARK: - Math

    private func l2normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
    }
}

// MARK: - VectorStoreError

public enum VectorStoreError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(UInt8)
    case writeFailed(underlying: Error)
    case truncatedData

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Vector store file has an unrecognized format."
        case .unsupportedVersion(let v):
            return "Vector store file version \(v) is not supported."
        case .writeFailed(let error):
            return "Failed to write vector store: \(error.localizedDescription)"
        case .truncatedData:
            return "Vector store file is truncated or corrupt."
        }
    }
}

// MARK: - Data write helpers

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        let v = value.littleEndian
        append(UInt8((v >> 0) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }

    mutating func appendUUID(_ value: UUID) {
        let t = value.uuid
        append(contentsOf: [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15
        ])
    }

    mutating func appendLengthPrefixedUTF8(_ string: String) {
        let utf8 = Data(string.utf8)
        appendUInt32(UInt32(utf8.count))
        append(utf8)
    }
}

// MARK: - DataCursor

private struct DataCursor {
    let data: Data
    var offset: Int = 0

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw VectorStoreError.truncatedData }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard offset + count <= data.count else { throw VectorStoreError.truncatedData }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw VectorStoreError.truncatedData }
        offset += count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw VectorStoreError.truncatedData }
        defer { offset += 4 }
        return data.withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    mutating func readInt32() throws -> Int32 {
        guard offset + 4 <= data.count else { throw VectorStoreError.truncatedData }
        defer { offset += 4 }
        return data.withUnsafeBytes { ptr in
            Int32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: Int32.self))
        }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readBytes(16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func readFloats(count: Int) throws -> [Float] {
        guard count >= 0 else { throw VectorStoreError.invalidFormat }
        guard offset + count * 4 <= data.count else { throw VectorStoreError.truncatedData }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let bits = data.withUnsafeBytes { ptr in
                UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self))
            }
            result[i] = Float(bitPattern: bits)
        }
        offset += count * 4
        return result
    }

    mutating func readLengthPrefixedUTF8() throws -> String {
        let length = Int(try readUInt32())
        guard offset + length <= data.count else { throw VectorStoreError.truncatedData }
        defer { offset += length }
        guard let string = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
            throw VectorStoreError.invalidFormat
        }
        return string
    }
}
