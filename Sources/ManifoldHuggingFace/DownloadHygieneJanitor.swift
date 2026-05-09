#if HuggingFace
import Foundation
import ManifoldInference
import os

internal struct DownloadHygieneJanitor {
    private let tempScanDirectory: URL
    private let tempFilePrefix: String
    private let tempFileExtension: String
    private let staleTempFileAge: TimeInterval

    internal init(
        tempScanDirectory: URL,
        tempFilePrefix: String,
        tempFileExtension: String,
        staleTempFileAge: TimeInterval
    ) {
        self.tempScanDirectory = tempScanDirectory
        self.tempFilePrefix = tempFilePrefix
        self.tempFileExtension = tempFileExtension
        self.staleTempFileAge = staleTempFileAge
    }

    @discardableResult
    internal func cleanupStaleTempFiles(
        now: Date,
        excluding excluded: Set<URL> = []
    ) -> (removed: Int, bytesReclaimed: Int64) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: tempScanDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.download.warning("Temp-file sweep skipped: could not list \(tempScanDirectory.path): \(error.localizedDescription)")
            return (0, 0)
        }

        let threshold = now.addingTimeInterval(-staleTempFileAge)
        var removed = 0
        var bytesReclaimed: Int64 = 0
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix(tempFilePrefix), fileURL.pathExtension == tempFileExtension else {
                continue
            }
            guard !excluded.contains(fileURL.resolvingSymlinksInPath()) else { continue }

            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: resourceKeys)
            } catch {
                Log.download.warning("Temp-file sweep: failed to read attributes of \(name): \(error.localizedDescription)")
                continue
            }
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < threshold else {
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            do {
                try FileManager.default.removeItem(at: fileURL)
                removed += 1
                bytesReclaimed += size
            } catch {
                Log.download.warning("Failed to remove stale temp file \(name): \(error.localizedDescription)")
            }
        }

        Log.download.info("Temp-file sweep: reclaimed \(removed) file(s), \(bytesReclaimed) byte(s)")
        return (removed, bytesReclaimed)
    }

    internal static func deleteOrphanedResumeDataFiles(in persistenceDirectory: URL, knownIDs: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: persistenceDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix("resume-") && fileURL.pathExtension == "bin" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let encodedID = String(filename.dropFirst("resume-".count))
            let decodedID = encodedID.removingPercentEncoding ?? encodedID
            if !knownIDs.contains(decodedID) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.download.info("Removed orphaned resume-data file: \(fileURL.lastPathComponent)")
                } catch {
                    Log.download.error("Failed to remove orphaned resume-data file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
                let tagURL = fileURL.appendingPathExtension("tag")
                do {
                    try FileManager.default.removeItem(at: tagURL)
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    Log.download.warning("Failed to remove orphaned resume tag file \(tagURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix("resume-") && fileURL.pathExtension == "tag" {
            let blobURL = fileURL.deletingPathExtension()
            if !FileManager.default.fileExists(atPath: blobURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.download.info("Removed dangling resume HMAC tag: \(fileURL.lastPathComponent)")
                } catch {
                    Log.download.warning("Failed to remove dangling resume HMAC tag \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}
#endif
