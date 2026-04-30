import Foundation

public struct FindingsMergeReport: Sendable, Equatable {
    public var totalRuns: Int
    public var uniqueFindings: Int
    public var mergedInputs: Int
}

public enum FindingsMerger {
    public static func merge(workerOutputDirs: [URL], into outputDir: URL) throws -> FindingsMergeReport {
        var totalRuns = 0
        var mergedByHash: [String: FindingsIndexRow] = [:]
        var canonicalSourceByHash: [String: URL] = [:]
        var mergedInputs = 0

        for workerOutputDir in workerOutputDirs {
            let index = try FindingsIndexCodec.load(from: workerOutputDir)
            guard index.totalRuns > 0 || !index.rows.isEmpty else { continue }
            mergedInputs += 1
            totalRuns += index.totalRuns

            for row in index.rows {
                let hash = row.finding.hash
                if var existing = mergedByHash[hash] {
                    existing.finding.count += row.finding.count
                    existing.finding.severity = max(existing.finding.severity, row.finding.severity)
                    existing.lastSeen = max(existing.lastSeen, row.lastSeen)
                    if row.finding.firstSeen < existing.finding.firstSeen {
                        var canonical = row
                        canonical.finding.count = existing.finding.count
                        canonical.finding.severity = existing.finding.severity
                        canonical.lastSeen = existing.lastSeen
                        mergedByHash[hash] = canonical
                        canonicalSourceByHash[hash] = workerOutputDir
                    } else {
                        mergedByHash[hash] = existing
                    }
                } else {
                    mergedByHash[hash] = row
                    canonicalSourceByHash[hash] = workerOutputDir
                }
            }
        }

        let rows = FindingsIndexCodec.sortedRows(Array(mergedByHash.values))
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let findingsDir = outputDir.appendingPathComponent("findings", isDirectory: true)
        try FileManager.default.createDirectory(at: findingsDir, withIntermediateDirectories: true)

        for row in rows {
            let finding = row.finding
            let destinationDir = findingsDir
                .appendingPathComponent(finding.detectorId, isDirectory: true)
                .appendingPathComponent(finding.hash, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            if let sourceRoot = canonicalSourceByHash[finding.hash] {
                let sourceDir = sourceRoot
                    .appendingPathComponent("findings", isDirectory: true)
                    .appendingPathComponent(finding.detectorId, isDirectory: true)
                    .appendingPathComponent(finding.hash, isDirectory: true)
                try copyFirstSeenRecord(from: sourceDir, to: destinationDir)
            }

            try FindingsArtifactRenderer.summary(for: row)
                .write(to: destinationDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            try FindingsArtifactRenderer.reproScript(hash: finding.hash, seed: row.seed, modelId: row.modelId)
                .write(to: destinationDir.appendingPathComponent("repro.sh"), atomically: true, encoding: .utf8)
        }

        try FindingsIndexCodec.write(FindingsIndexFile(totalRuns: totalRuns, rows: rows), to: outputDir)
        return FindingsMergeReport(totalRuns: totalRuns, uniqueFindings: rows.count, mergedInputs: mergedInputs)
    }

    private static func copyFirstSeenRecord(from sourceDir: URL, to destinationDir: URL) throws {
        let source = sourceDir.appendingPathComponent("record.json")
        let destination = destinationDir.appendingPathComponent("record.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
