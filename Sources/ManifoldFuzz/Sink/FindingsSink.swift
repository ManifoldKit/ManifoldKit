import Foundation
import ManifoldInference

/// Writes `RunRecord`s and `Finding`s to disk, deduping per finding hash and
/// regenerating `INDEX.md` on every flush.
public actor FindingsSink {

    private let outputDir: URL
    private var index: [String: FindingsIndexRow] = [:]
    private var totalRuns = 0

    public init(outputDir: URL) {
        self.outputDir = outputDir
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: outputDir.appendingPathComponent("findings", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            Self.logError("Failed to create FindingsSink output directories at \(outputDir.path): \(error)")
        }
        // Load existing index synchronously; safe because nothing else holds this actor yet.
        do {
            let loaded = try FindingsIndexCodec.load(from: outputDir)
            self.totalRuns = loaded.totalRuns
            self.index = Dictionary(uniqueKeysWithValues: loaded.rows.map { ($0.finding.hash, $0) })
        } catch {
            let indexURL = outputDir.appendingPathComponent("index.json")
            Log.inference.warning("FindingsSink: failed to load existing index.json at \(indexURL.path, privacy: .public); starting fresh: \(String(describing: error), privacy: .public)")
        }
    }

    /// Increments `totalRuns` and rewrites `INDEX.md` so empty runs leave a
    /// visible trace ("12 total runs, 0 unique findings").
    public func noteEmptyRun() {
        totalRuns += 1
        writeIndex()
    }

    public func recordRun(_ record: RunRecord, findings: [Finding]) {
        totalRuns += 1
        for finding in findings {
            var stored = finding
            let isFirstSighting = index[finding.hash] == nil
            if let prior = index[finding.hash] {
                stored.count = prior.finding.count + 1
                stored.firstSeen = prior.finding.firstSeen
            }
            let dir = outputDir
                .appendingPathComponent("findings", isDirectory: true)
                .appendingPathComponent(finding.detectorId, isDirectory: true)
                .appendingPathComponent(finding.hash, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Self.logError("Failed to create finding directory at \(dir.path): \(error)")
                continue
            }

            let priorSeed = index[finding.hash]?.seed
            let recordedSeed = isFirstSighting ? record.config.seed : (priorSeed ?? record.config.seed)

            // Only write record.json on first sight: it captures the cleanest minimal repro
            // and any later overwrite would mask the original triggering input.
            if isFirstSighting {
                let recordURL = dir.appendingPathComponent("record.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    let data = try encoder.encode(record)
                    try data.write(to: recordURL)
                } catch {
                    Self.logError("Failed to write record.json for finding \(finding.hash) at \(recordURL.path): \(error)")
                }
            }

            let row = FindingsIndexRow(
                finding: stored,
                modelId: record.model.id,
                seed: recordedSeed,
                lastSeen: ISO8601DateFormatter().string(from: Date())
            )
            do {
                try FindingsArtifactRenderer.summary(for: row)
                    .write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            } catch {
                Self.logError("Failed to write summary.txt for finding \(finding.hash): \(error)")
            }

            do {
                try FindingsArtifactRenderer.reproScript(
                    hash: finding.hash,
                    seed: recordedSeed,
                    modelId: record.model.id,
                    outputDir: outputDir
                )
                    .write(to: dir.appendingPathComponent("repro.sh"), atomically: true, encoding: .utf8)
            } catch {
                Self.logError("Failed to write repro.sh for finding \(finding.hash): \(error)")
            }

            index[finding.hash] = row
        }
        writeIndex()
    }

    public func snapshot() -> (totalRuns: Int, findings: [Finding]) {
        (totalRuns, index.values.map { $0.finding })
    }

    private func writeIndex() {
        do {
            try FindingsIndexCodec.write(
                FindingsIndexFile(totalRuns: totalRuns, rows: Array(index.values)),
                to: outputDir
            )
        } catch {
            Self.logError("Failed to write findings index at \(outputDir.path): \(error)")
        }
    }

    private static func logError(_ message: String) {
        Log.inference.error("FindingsSink: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("FindingsSink error: \(message)\n".utf8))
    }
}
