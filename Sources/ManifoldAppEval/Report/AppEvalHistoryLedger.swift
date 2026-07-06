import Foundation
import ManifoldInference

/// One row of the append-only `history.jsonl` ledger — one fixture's verdict
/// from one run.
///
/// Schema-versioned (fireside's `SCHEMA.md` pattern, adopted as spec):
/// - `schemaVersion` lets a future reader detect which optional fields to
///   expect.
/// - Optional fields are omitted entirely when absent (not encoded as
///   `null`) — `encode(to:)` uses `encodeIfPresent` throughout.
/// - `decode(from:)` only reads the fields this version knows about,
///   so a **newer** writer's added fields are silently ignored by an
///   **older** reader (`JSONDecoder` already ignores unrecognized keys by
///   default; there is nothing else to opt into for forward tolerance).
public struct AppEvalLedgerEntry: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let fixtureID: String
    public let verdict: String
    public let checkpointCount: Int
    /// Labels of checkpoints that had at least one failing assertion, or
    /// `nil` when every checkpoint passed (omitted from the JSON line, not
    /// encoded as an empty array, to keep passing rows minimal).
    public let failingCheckpointLabels: [String]?

    public init(
        fixtureID: String,
        verdict: AppEvalVerdict,
        checkpointCount: Int,
        failingCheckpointLabels: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.fixtureID = fixtureID
        self.verdict = verdict.ledgerValue
        self.checkpointCount = checkpointCount
        self.failingCheckpointLabels = failingCheckpointLabels.isEmpty ? nil : failingCheckpointLabels
    }
}

extension AppEvalLedgerEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, fixtureID, verdict, checkpointCount, failingCheckpointLabels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        fixtureID = try container.decode(String.self, forKey: .fixtureID)
        verdict = try container.decode(String.self, forKey: .verdict)
        checkpointCount = try container.decode(Int.self, forKey: .checkpointCount)
        failingCheckpointLabels = try container.decodeIfPresent([String].self, forKey: .failingCheckpointLabels)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(fixtureID, forKey: .fixtureID)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(checkpointCount, forKey: .checkpointCount)
        try container.encodeIfPresent(failingCheckpointLabels, forKey: .failingCheckpointLabels)
    }
}

private extension AppEvalVerdict {
    var ledgerValue: String {
        switch self {
        case .pass: return "pass"
        case .fail: return "fail"
        case .error: return "error"
        }
    }
}

// MARK: - AppEvalHistoryLedger

/// Reads and writes the `history.jsonl` ledger: one sorted-keys JSON object
/// per line, appended — never rewritten in place — so concurrent CI runs
/// never race on a read-modify-write of the whole file.
public enum AppEvalHistoryLedger {

    /// Appends one line per fixture in `outcome`, sorted by fixture id for
    /// stable output within a single append call.
    public static func append(_ outcome: AppEvalOutcome, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for fixture in outcome.fixtures.sorted(by: { $0.fixtureID < $1.fixtureID }) {
            let entry = AppEvalLedgerEntry(
                fixtureID: fixture.fixtureID,
                verdict: fixture.verdict,
                checkpointCount: fixture.checkpoints.count,
                failingCheckpointLabels: failingLabels(fixture)
            )
            let data = try encoder.encode(entry)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        let appended = lines.map { $0 + "\n" }.joined()
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            guard let data = appended.data(using: .utf8) else {
                throw LedgerError.encodingFailed
            }
            handle.write(data)
        } else {
            try appended.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Decodes every line of `url` as an ``AppEvalLedgerEntry``, in file order.
    /// Blank lines are skipped; a malformed line throws immediately with its
    /// line number so a corrupt ledger is diagnosable.
    public static func read(from url: URL) throws -> [AppEvalLedgerEntry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var entries: [AppEvalLedgerEntry] = []
        for (lineNumber, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw LedgerError.decodingFailed(line: lineNumber + 1)
            }
            do {
                entries.append(try decoder.decode(AppEvalLedgerEntry.self, from: data))
            } catch {
                throw LedgerError.malformedLine(line: lineNumber + 1, underlying: error)
            }
        }
        return entries
    }

    public enum LedgerError: Error, CustomStringConvertible {
        case encodingFailed
        case decodingFailed(line: Int)
        case malformedLine(line: Int, underlying: Error)

        public var description: String {
            switch self {
            case .encodingFailed:
                return "AppEvalHistoryLedger: failed to UTF-8 encode a ledger line"
            case .decodingFailed(let line):
                return "AppEvalHistoryLedger: line \(line) is not valid UTF-8"
            case .malformedLine(let line, let underlying):
                return "AppEvalHistoryLedger: line \(line) failed to decode: \(underlying)"
            }
        }
    }

    private static func failingLabels(_ fixture: FixtureOutcome) -> [String] {
        fixture.checkpoints.filter { checkpoint in
            checkpoint.scores.values.contains { score in
                if case .bool(false) = score.value { return true }
                return false
            }
        }.map(\.label)
    }
}
