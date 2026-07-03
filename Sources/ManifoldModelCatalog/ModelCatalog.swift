import Foundation
import ManifoldHardware

/// Sidecar metadata catalog layered over ``ModelStorageService``.
///
/// ``ModelStorageService`` remains the source of truth for on-disk presence.
/// The catalog stores metadata that is not reliably derivable from the model
/// artifact itself: source provenance, download time, last-used time, expected
/// integrity hash, and quantization labels.
///
/// > Not yet wired: as of the 2026-07-03 inert-surface audit, no production
/// > code path constructs a `ModelCatalog`. `ManifoldBootstrap`,
/// > `ModelManagementViewModel`, and `ModelRegistry` all use
/// > `ModelStorageService` directly and never reference this type. `.touch(_:)`
/// > (which CHANGELOG v0.22.0 describes as "called automatically on every
/// > successful model load") has zero production call sites — only this
/// > type's own tests construct and exercise a `ModelCatalog`. A host that
/// > wants the sidecar-manifest behavior (download provenance, LRU
/// > disk-budget eviction) must construct and drive one itself.
public actor ModelCatalog {

    public static let manifestFileName = ".manifold-catalog.json"

    private let storage: ModelStorageService
    private let fileManager: FileManager
    private let manifestURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        storage: ModelStorageService,
        fileManager: FileManager = .default,
        manifestURL: URL? = nil
    ) {
        self.storage = storage
        self.fileManager = fileManager
        self.manifestURL = manifestURL ?? storage.modelsDirectory.appendingPathComponent(Self.manifestFileName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Returns the manifest-backed catalog, reconciled against current disk state.
    ///
    /// If the manifest is missing or corrupt, the catalog rebuilds from
    /// ``ModelStorageService/discoverModels()`` and persists the rebuilt snapshot.
    /// If the manifest is valid but stale, disk presence still wins: missing
    /// artifacts are dropped and newly discovered artifacts are backfilled as
    /// ``ModelSource/imported`` entries.
    public func catalog() async throws -> [CatalogEntry] {
        let manifest = try loadManifestOrRebuild()
        let reconciled = try reconcile(manifest.entries)
        if reconciled != manifest.entries {
            try write(entries: reconciled)
        }
        return sorted(reconciled)
    }

    /// Records or replaces metadata for a model after a successful import/download.
    public func record(_ entry: CatalogEntry) async throws {
        let entries = try await catalog()
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        byID[entry.id] = entry
        try write(entries: Array(byID.values))
    }

    /// Removes a catalog entry and optionally deletes its on-disk artifact.
    @discardableResult
    public func evict(_ id: ModelInfo.ID, deleteArtifact: Bool) async throws -> CatalogEntry? {
        var entries = try await catalog()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = entries.remove(at: index)
        if deleteArtifact {
            try deleteArtifactIfPresent(for: removed)
        }
        try write(entries: entries)
        return removed
    }

    /// Evicts least-recently-used entries until the catalog fits within `maxBytes`.
    ///
    /// Artifacts are deleted for evicted entries. Missing artifacts are ignored by
    /// the deletion step because reconciliation already treats disk as truth.
    @discardableResult
    public func enforceDiskBudget(_ maxBytes: UInt64) async throws -> [CatalogEntry] {
        var entries = try await catalog()
        var total = entries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        guard total > maxBytes else { return [] }

        let victims = entries.sorted {
            if $0.lastUsedAt == $1.lastUsedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.lastUsedAt < $1.lastUsedAt
        }

        var evicted: [CatalogEntry] = []
        for victim in victims where total > maxBytes {
            try deleteArtifactIfPresent(for: victim)
            entries.removeAll { $0.id == victim.id }
            total = total >= victim.sizeBytes ? total - victim.sizeBytes : 0
            evicted.append(victim)
        }

        try write(entries: entries)
        return evicted
    }

    /// Updates last-used time for a cataloged model.
    public func touch(_ id: ModelInfo.ID, at date: Date = Date()) async throws {
        var entries = try await catalog()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].lastUsedAt = date
        try write(entries: entries)
    }

    // MARK: - Private

    private func loadManifestOrRebuild() throws -> CatalogManifest {
        do {
            let data = try Data(contentsOf: manifestURL)
            return try decoder.decode(CatalogManifest.self, from: data)
        } catch let cocoaError as CocoaError where cocoaError.code == .fileReadNoSuchFile {
            return try rebuildManifest()
        } catch {
            Log.inference.warning("ModelCatalog: rebuilding corrupt manifest at \(self.manifestURL.path): \(error.localizedDescription)")
            return try rebuildManifest()
        }
    }

    private func rebuildManifest() throws -> CatalogManifest {
        let entries = storage.discoverModels().map { CatalogEntry(modelInfo: $0, source: .imported) }
        try write(entries: entries)
        return CatalogManifest(entries: entries)
    }

    private func reconcile(_ entries: [CatalogEntry]) throws -> [CatalogEntry] {
        let discovered = storage.discoverModels()
        let discoveredKeys = Set(discovered.map { artifactKey(for: $0.url) })
        let existing = entries.filter { discoveredKeys.contains(artifactKey(for: $0.modelInfo.url)) }

        var keys = Set(existing.map { artifactKey(for: $0.modelInfo.url) })
        var reconciled = existing
        for model in discovered where !keys.contains(artifactKey(for: model.url)) {
            reconciled.append(CatalogEntry(modelInfo: model, source: .imported))
            keys.insert(artifactKey(for: model.url))
        }
        return reconciled
    }

    private func write(entries: [CatalogEntry]) throws {
        try storage.ensureModelsDirectory()
        let manifest = CatalogManifest(entries: sorted(entries))
        let data = try encoder.encode(manifest)
        let tempURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(manifestURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: [.atomic])
        if fileManager.fileExists(atPath: manifestURL.path) {
            _ = try fileManager.replaceItemAt(manifestURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: manifestURL)
        }
    }

    private func deleteArtifactIfPresent(for entry: CatalogEntry) throws {
        let url = entry.modelInfo.url
        do {
            try fileManager.removeItem(at: url)
        } catch let cocoaError as CocoaError where cocoaError.code == .fileNoSuchFile {
            return
        }
    }

    private func sorted(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.sorted {
            let nameOrder = $0.modelInfo.name.localizedStandardCompare($1.modelInfo.name)
            if nameOrder == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return nameOrder == .orderedAscending
        }
    }

    private func artifactKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// Metadata source for a cataloged model.
public enum ModelSource: Codable, Hashable, Sendable {
    case huggingFace(repo: String, file: String)
    case imported
    case bundled
}

/// One manifest row in ``ModelCatalog``.
public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let modelInfo: ModelInfo
    public let source: ModelSource
    public let downloadedAt: Date
    public var lastUsedAt: Date
    public let expectedSHA256: String?
    public let sizeBytes: UInt64
    public var quantization: String?

    public init(
        id: UUID? = nil,
        modelInfo: ModelInfo,
        source: ModelSource,
        downloadedAt: Date = Date(),
        lastUsedAt: Date = Date(),
        expectedSHA256: String? = nil,
        sizeBytes: UInt64? = nil,
        quantization: String? = nil
    ) {
        self.id = id ?? modelInfo.id
        self.modelInfo = modelInfo
        self.source = source
        self.downloadedAt = downloadedAt
        self.lastUsedAt = lastUsedAt
        self.expectedSHA256 = expectedSHA256
        self.sizeBytes = sizeBytes ?? modelInfo.fileSize
        self.quantization = quantization ?? Self.quantization(from: modelInfo.fileName)
    }
}

extension CatalogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case modelInfo
        case source
        case downloadedAt
        case lastUsedAt
        case expectedSHA256
        case sizeBytes
        case quantization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        modelInfo = try container.decode(ModelInfoSnapshot.self, forKey: .modelInfo).modelInfo
        source = try container.decode(ModelSource.self, forKey: .source)
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        sizeBytes = try container.decode(UInt64.self, forKey: .sizeBytes)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ModelInfoSnapshot(modelInfo), forKey: .modelInfo)
        try container.encode(source, forKey: .source)
        try container.encode(downloadedAt, forKey: .downloadedAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(expectedSHA256, forKey: .expectedSHA256)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(quantization, forKey: .quantization)
    }
}

private struct CatalogManifest: Codable, Equatable {
    var version: Int = 1
    var entries: [CatalogEntry]
}

private struct ModelInfoSnapshot: Codable, Equatable {
    var id: UUID
    var name: String
    var fileName: String
    var url: URL
    var fileSize: UInt64
    var modelType: StoredModelType
    var mmprojURL: URL?
    var huggingFaceRepoID: String?
    // Resolved capability flags survive without a re-probe. Both the curated
    // override and detected layers are persisted so the override-over-detected
    // resolution round-trips exactly (a re-probe can still refresh `detected*`
    // without clobbering a host's curation). All optional + decodeIfPresent so
    // catalogs written before this field shipped decode cleanly (nil = absent).
    var curatedSupportsCode: Bool?
    var detectedSupportsCode: Bool?
    var curatedSupportsMultilingual: Bool?
    var detectedSupportsMultilingual: Bool?
    var curatedSupportsReasoning: Bool?
    var detectedSupportsReasoning: Bool?

    init(_ modelInfo: ModelInfo) {
        id = modelInfo.id
        name = modelInfo.name
        fileName = modelInfo.fileName
        url = modelInfo.url
        fileSize = modelInfo.fileSize
        modelType = StoredModelType(modelInfo.modelType)
        mmprojURL = modelInfo.mmprojURL
        huggingFaceRepoID = modelInfo.huggingFaceRepoID
        curatedSupportsCode = modelInfo.curatedSupportsCode
        detectedSupportsCode = modelInfo.detectedSupportsCode
        curatedSupportsMultilingual = modelInfo.curatedSupportsMultilingual
        detectedSupportsMultilingual = modelInfo.detectedSupportsMultilingual
        curatedSupportsReasoning = modelInfo.curatedSupportsReasoning
        detectedSupportsReasoning = modelInfo.detectedSupportsReasoning
    }

    var modelInfo: ModelInfo {
        ModelInfo(
            id: id,
            name: name,
            fileName: fileName,
            url: url,
            fileSize: fileSize,
            modelType: modelType.modelType,
            mmprojURL: mmprojURL,
            huggingFaceRepoID: huggingFaceRepoID,
            curatedSupportsCode: curatedSupportsCode,
            detectedSupportsCode: detectedSupportsCode,
            curatedSupportsMultilingual: curatedSupportsMultilingual,
            detectedSupportsMultilingual: detectedSupportsMultilingual,
            curatedSupportsReasoning: curatedSupportsReasoning,
            detectedSupportsReasoning: detectedSupportsReasoning
        )
    }
}

private enum StoredModelType: String, Codable {
    case gguf
    case mlx
    case foundation

    init(_ modelType: ModelType) {
        switch modelType {
        case .gguf: self = .gguf
        case .mlx: self = .mlx
        case .foundation: self = .foundation
        }
    }

    var modelType: ModelType {
        switch self {
        case .gguf: .gguf
        case .mlx: .mlx
        case .foundation: .foundation
        }
    }
}

private extension CatalogEntry {
    static func quantization(from fileName: String) -> String? {
        guard fileName.lowercased().hasSuffix(".gguf") else { return nil }
        let pattern = #"[_\-\.]((?:Q|IQ|F|BF)\d+(?:_[A-Z0-9]+){0,5})\."#
        let boundedName = String(fileName.prefix(128))
        guard let range = boundedName.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(boundedName[range].dropFirst().dropLast())
    }
}
