import Foundation

public struct FindingsIndexRow: Codable, Sendable, Equatable {
    public var finding: Finding
    public var modelId: String
    public var seed: UInt64
    public var lastSeen: String

    public init(finding: Finding, modelId: String, seed: UInt64, lastSeen: String) {
        self.finding = finding
        self.modelId = modelId
        self.seed = seed
        self.lastSeen = lastSeen
    }
}

public struct FindingsIndexFile: Codable, Sendable, Equatable {
    public var totalRuns: Int
    public var rows: [FindingsIndexRow]

    public init(totalRuns: Int, rows: [FindingsIndexRow]) {
        self.totalRuns = totalRuns
        self.rows = rows
    }
}

public enum FindingsIndexCodec {
    public static func load(from outputDir: URL) throws -> FindingsIndexFile {
        let indexURL = outputDir.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return FindingsIndexFile(totalRuns: 0, rows: [])
        }

        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(FindingsIndexFile.self, from: data)
        } catch {
            let rows = try decoder.decode([FindingsIndexRow].self, from: data)
            return FindingsIndexFile(totalRuns: rows.count, rows: rows)
        }
    }

    public static func write(_ index: FindingsIndexFile, to outputDir: URL) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outputDir.appendingPathComponent("findings", isDirectory: true),
            withIntermediateDirectories: true
        )

        let rows = sortedRows(index.rows)
        let envelope = FindingsIndexFile(totalRuns: index.totalRuns, rows: rows)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: outputDir.appendingPathComponent("index.json"))

        let markdown = FindingsArtifactRenderer.markdown(totalRuns: index.totalRuns, rows: rows)
        try markdown.write(to: outputDir.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
    }

    public static func sortedRows(_ rows: [FindingsIndexRow]) -> [FindingsIndexRow] {
        rows.sorted { lhs, rhs in
            if lhs.finding.severity != rhs.finding.severity {
                return lhs.finding.severity > rhs.finding.severity
            }
            return lhs.finding.count > rhs.finding.count
        }
    }
}

public enum FindingsArtifactRenderer {
    public static func summary(for row: FindingsIndexRow) -> String {
        let finding = row.finding
        return "\(finding.severity.rawValue) | \(finding.detectorId)/\(finding.subCheck) | \(finding.modelId) | count=\(finding.count)\nTrigger: \(finding.trigger)\n"
    }

    public static func reproScript(hash: String, seed: UInt64, modelId: String) -> String {
        """
        #!/bin/sh
        # Preferred: bit-level replay against the recorded prompt/config.
        \(replayCommand(hash: hash))
        # Fallback: re-enter the campaign loop at the original seed/model.
        # \(reproCommand(seed: seed, modelId: modelId))

        """
    }

    public static func markdown(totalRuns: Int, rows: [FindingsIndexRow]) -> String {
        var md = "# Fuzz findings\n\n"
        md += "_\(totalRuns) total runs, \(rows.count) unique findings._\n\n"
        md += "| Severity | Detector / sub-check | Model | Hash | First seen | Count | Trigger | Replay |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let finding = row.finding
            let trigger = finding.trigger.replacingOccurrences(of: "|", with: "\\|").prefix(80)
            md += "| \(finding.severity.rawValue) | \(finding.detectorId) / \(finding.subCheck) | \(row.modelId) | `\(finding.hash)` | \(finding.firstSeen) | \(finding.count) | \(trigger) | `\(replayCommand(hash: finding.hash))` |\n"
        }
        return md
    }

    public static func reproCommand(seed: UInt64, modelId: String) -> String {
        "swift run fuzz-chat --seed \(seed) --model \(modelId) --single"
    }

    public static func replayCommand(hash: String) -> String {
        "swift run fuzz-chat --replay \(hash)"
    }
}
