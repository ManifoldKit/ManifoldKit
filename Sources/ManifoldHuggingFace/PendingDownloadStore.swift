#if HuggingFace
import CryptoKit
import Foundation
import ManifoldInference
import os

internal struct SnapshotFileMetadata: Codable, Sendable {
    let relativePath: String
    let sizeBytes: UInt64
    let expectedChecksum: ModelFileChecksum?
}

internal final class PendingDownloadStore {
    internal let persistenceDirectory: URL
    private let userDefaults: UserDefaults

    internal init(persistenceDirectory: URL, userDefaults: UserDefaults) {
        self.persistenceDirectory = persistenceDirectory
        self.userDefaults = userDefaults
    }

    internal var pendingMetadataFileURL: URL {
        persistenceDirectory.appendingPathComponent("pending-downloads.json")
    }

    internal func resumeDataFileURL(for id: String) -> URL {
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return persistenceDirectory.appendingPathComponent("resume-\(safeID).bin")
    }

    internal func resumeDataTagURL(for id: String) -> URL {
        resumeDataFileURL(for: id).appendingPathExtension("tag")
    }

    private func ensurePersistenceDirectory() throws {
        try FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true)
    }

    internal func loadPendingMetadata() -> [String: [String: String]]? {
        do {
            let data = try Data(contentsOf: pendingMetadataFileURL)
            return try JSONDecoder().decode([String: [String: String]].self, from: data)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.download.warning("Failed to load pending-download metadata: \(error.localizedDescription)")
            return nil
        }
    }

    internal func writePendingMetadata(_ pending: [String: [String: String]]) throws {
        try ensurePersistenceDirectory()
        let data = try JSONEncoder().encode(pending)
        let tempURL = pendingMetadataFileURL.deletingLastPathComponent()
            .appendingPathComponent("pending-downloads-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: pendingMetadataFileURL.path) {
            _ = try FileManager.default.replaceItemAt(
                pendingMetadataFileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: tempURL, to: pendingMetadataFileURL)
        }
    }

    internal func savePendingDownload(
        model: DownloadableModel,
        snapshotFiles: [SnapshotFileMetadata] = [],
        stagingDirectoryName: String? = nil
    ) throws {
        var pending = loadPendingMetadata() ?? [:]
        var entry = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx",
            "sizeBytes": String(model.sizeBytes),
        ]
        if let packageKind = model.packageKind {
            entry["packageKind"] = packageKind.rawValue
        }
        if !snapshotFiles.isEmpty {
            let data = try JSONEncoder().encode(snapshotFiles)
            guard let json = String(data: data, encoding: .utf8) else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to encode pending snapshot metadata")
            }
            entry["snapshotFiles"] = json
        }
        if let stagingDirectoryName {
            entry["stagingDirectoryName"] = stagingDirectoryName
        }
        pending[model.id] = entry
        try writePendingMetadata(pending)
    }

    internal func removePendingDownload(id: String) {
        var pending = loadPendingMetadata() ?? [:]
        pending.removeValue(forKey: id)
        do {
            try writePendingMetadata(pending)
        } catch {
            Log.download.error("Failed to remove pending download for \(id): \(error.localizedDescription)")
        }
        removeResumeDataFiles(dataURL: resumeDataFileURL(for: id), tagURL: resumeDataTagURL(for: id))
    }

    internal func persistResumeData(_ data: Data, for id: String) {
        do {
            try ensurePersistenceDirectory()
            try data.write(to: resumeDataFileURL(for: id), options: .atomic)
            do {
                let tag = try Self.computeResumeHMACTag(for: data)
                try tag.write(to: resumeDataTagURL(for: id), options: .atomic)
                Log.download.info("Persisted \(data.count) bytes of resume data for \(id) (HMAC \(tag.count)-byte tag)")
            } catch {
                Log.download.error("Failed to write resume HMAC tag for \(id): \(error.localizedDescription)")
                removeResumeTag(for: id)
            }
        } catch {
            Log.download.error("Failed to persist resume data for \(id): \(error.localizedDescription)")
        }
    }

    internal func consumeResumeData(for id: String) -> Data? {
        let dataURL = resumeDataFileURL(for: id)
        let tagURL = resumeDataTagURL(for: id)

        let data: Data
        do {
            data = try Data(contentsOf: dataURL)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.download.warning("Failed to read resume data for \(id): \(error.localizedDescription); falling back to fresh download")
            removeResumeDataFiles(dataURL: dataURL, tagURL: tagURL)
            return nil
        }

        let tag: Data
        do {
            tag = try Data(contentsOf: tagURL)
        } catch {
            Log.download.warning("Resume data for \(id) is missing its HMAC tag; rejecting and falling back to fresh download")
            removeResumeDataFiles(dataURL: dataURL, tagURL: tagURL)
            return nil
        }

        let expected: Data
        do {
            expected = try Self.computeResumeHMACTag(for: data)
        } catch {
            Log.download.error("Failed to compute resume HMAC for \(id): \(error.localizedDescription); rejecting and falling back to fresh download")
            removeResumeDataFiles(dataURL: dataURL, tagURL: tagURL)
            return nil
        }

        guard Self.constantTimeEqual(expected, tag) else {
            Log.network.error("Resume data HMAC mismatch for \(id) — rejecting blob and falling back to fresh download")
            removeResumeDataFiles(dataURL: dataURL, tagURL: tagURL)
            return nil
        }

        removeResumeDataFiles(dataURL: dataURL, tagURL: tagURL)
        return data
    }

    private func removeResumeTag(for id: String) {
        do {
            try FileManager.default.removeItem(at: resumeDataTagURL(for: id))
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Log.download.warning("Failed to remove stale resume HMAC tag for \(id): \(error.localizedDescription)")
        }
    }

    private func removeResumeDataFiles(dataURL: URL, tagURL: URL) {
        for url in [dataURL, tagURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Log.download.warning("Failed to remove resume artefact at \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    internal func migrateFromUserDefaults() {
        let pendingKey = ManifoldConfiguration.shared.pendingDownloadsKey

        if !FileManager.default.fileExists(atPath: pendingMetadataFileURL.path),
           let legacy = userDefaults.dictionary(forKey: pendingKey) as? [String: [String: String]],
           !legacy.isEmpty {
            do {
                try writePendingMetadata(legacy)
                userDefaults.removeObject(forKey: pendingKey)
                Log.download.info("Migrated \(legacy.count) pending-download(s) from UserDefaults to file")
            } catch {
                Log.download.error("Failed to migrate pending downloads from UserDefaults: \(error.localizedDescription)")
            }
        } else {
            userDefaults.removeObject(forKey: pendingKey)
        }

        let allKeys = userDefaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("resumeData.") {
            let id = String(key.dropFirst("resumeData.".count))
            if let data = userDefaults.data(forKey: key) {
                persistResumeData(data, for: id)
                if FileManager.default.fileExists(atPath: resumeDataFileURL(for: id).path),
                   FileManager.default.fileExists(atPath: resumeDataTagURL(for: id).path) {
                    userDefaults.removeObject(forKey: key)
                    Log.download.info("Migrated resume data for \(id) from UserDefaults to file")
                } else {
                    Log.download.warning("Resume-data migration for \(id) did not produce a tagged pair; leaving UserDefaults key intact")
                }
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
    }

    internal static let resumeHMACKeychainAccount: String = "com.basechat.resumedata.hmac"

    private static let resumeHMACLock = NSLock()
    private nonisolated(unsafe) static var _cachedResumeHMACKey: SymmetricKey?

    internal static func computeResumeHMACTag(for data: Data) throws -> Data {
        let key = try resumeHMACKey()
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    private static func resumeHMACKey() throws -> SymmetricKey {
        resumeHMACLock.lock()
        if let cached = _cachedResumeHMACKey {
            resumeHMACLock.unlock()
            return cached
        }
        resumeHMACLock.unlock()

        if let stored = KeychainService.retrieve(account: resumeHMACKeychainAccount),
           let bytes = Data(base64Encoded: stored), bytes.count >= 32 {
            let key = SymmetricKey(data: bytes)
            resumeHMACLock.lock()
            _cachedResumeHMACKey = key
            resumeHMACLock.unlock()
            return key
        }

        let fresh = SymmetricKey(size: .bits256)
        let encoded = fresh.withUnsafeBytes { Data($0) }.base64EncodedString()
        do {
            try KeychainService.store(key: encoded, account: resumeHMACKeychainAccount)
        } catch {
            Log.security.warning(
                "BackgroundDownloadManager: Keychain write for resume HMAC key failed (\(error.localizedDescription, privacy: .public)); using process-local key"
            )
        }
        resumeHMACLock.lock()
        _cachedResumeHMACKey = fresh
        resumeHMACLock.unlock()
        return fresh
    }

    internal static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[lhs.startIndex.advanced(by: i)] ^ rhs[rhs.startIndex.advanced(by: i)]
        }
        return diff == 0
    }

    internal static func _resetResumeHMACKeyCacheForTesting() {
        resumeHMACLock.lock()
        _cachedResumeHMACKey = nil
        resumeHMACLock.unlock()
    }
}
#endif
