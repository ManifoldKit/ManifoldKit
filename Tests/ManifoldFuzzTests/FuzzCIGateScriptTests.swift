import XCTest

/// Integration test for `scripts/fuzz-ci-gate.sh`. The gate is the enforcement
/// point for the weekly fuzz job (`.github/workflows/fuzz-weekly.yml`, #2367);
/// its correctness matters as much as the harness itself. Covers the three
/// branches from the task brief:
///   1. finding present + matching unexpired allowlist entry → exit 0
///   2. finding present + empty allowlist              → exit 1
///   3. allowlist entry past `expires`                 → exit 1
/// plus a fourth happy-path (zero findings, empty allowlist), a fifth
/// covering the missing-`index.json` branch (#2367 review): a campaign that
/// never wrote one never ran, and must fail the gate rather than pass
/// vacuously — see the comment on that branch in fuzz-ci-gate.sh itself —
/// and a sixth covering a *present but stale* `index.json` reporting
/// `totalRuns <= 0`: the missing-file check alone is only safe because
/// `tmp/` is gitignored and checkout defaults to `clean: true`; a leftover
/// file from an earlier run (e.g. `clean: false`) must be caught too.
///
/// The test skips in environments without `python3` or the repo checkout — the
/// gate script shells out to python3 to parse JSON + compare dates.
final class FuzzCIGateScriptTests: XCTestCase {

    private func repoRoot() -> URL? {
        // #file is .../Tests/ManifoldFuzzTests/FuzzCIGateScriptTests.swift
        // repo root is two levels above Tests/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return candidate
    }

    private func writeIndex(hash: String?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-gate-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let indexURL = tmp.appendingPathComponent("index.json")
        let rows: String
        if let hash {
            rows = """
            {
              "finding": {
                "hash": "\(hash)",
                "detectorId": "empty-output-after-work",
                "subCheck": "silent-empty",
                "severity": "flaky",
                "modelId": "mock-model",
                "trigger": "prompt",
                "firstSeen": "2026-04-19T00:00:00Z",
                "count": 1
              },
              "modelId": "mock-model",
              "seed": 1,
              "lastSeen": "2026-04-19T00:00:00Z"
            }
            """
        } else {
            rows = ""
        }
        let json = "{\"totalRuns\": 1, \"rows\": [\(rows)]}"
        try json.write(to: indexURL, atomically: true, encoding: .utf8)
        return indexURL
    }

    private func writeIndex(totalRuns: Int, hash: String?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-gate-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let indexURL = tmp.appendingPathComponent("index.json")
        let rows: String
        if let hash {
            rows = """
            {
              "finding": {
                "hash": "\(hash)",
                "detectorId": "empty-output-after-work",
                "subCheck": "silent-empty",
                "severity": "flaky",
                "modelId": "mock-model",
                "trigger": "prompt",
                "firstSeen": "2026-04-19T00:00:00Z",
                "count": 1
              },
              "modelId": "mock-model",
              "seed": 1,
              "lastSeen": "2026-04-19T00:00:00Z"
            }
            """
        } else {
            rows = ""
        }
        let json = "{\"totalRuns\": \(totalRuns), \"rows\": [\(rows)]}"
        try json.write(to: indexURL, atomically: true, encoding: .utf8)
        return indexURL
    }

    private func writeAllowlist(entries: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-gate-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("allowlist.json")
        try "{\"allowlist\": [\(entries)]}".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func run(script: URL, args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Tests

    func test_findingMatchesUnexpiredAllowlist_exitsZero() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let index = try writeIndex(hash: "aaaa1111bbbb")
        let allow = try writeAllowlist(entries: """
        {"hash":"aaaa1111bbbb","reason":"test","expires":"2099-12-31"}
        """)
        let status = try run(script: script, args: [index.path, allow.path])
        XCTAssertEqual(status, 0, "matching unexpired allowlist entry must pass the gate")
    }

    func test_findingWithEmptyAllowlist_exitsOne() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let index = try writeIndex(hash: "cccc2222dddd")
        let allow = try writeAllowlist(entries: "")
        let status = try run(script: script, args: [index.path, allow.path])
        XCTAssertEqual(status, 1, "a finding with no allowlist coverage must fail the gate")
    }

    func test_expiredAllowlistEntry_exitsOne() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let index = try writeIndex(hash: "eeee3333ffff")
        let allow = try writeAllowlist(entries: """
        {"hash":"eeee3333ffff","reason":"test","expires":"2020-01-01"}
        """)
        let status = try run(script: script, args: [index.path, allow.path])
        XCTAssertEqual(status, 1, "an expired allowlist entry must force triage (exit 1) even when the hash matches")
    }

    func test_noFindings_exitsZero() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let index = try writeIndex(hash: nil)
        let allow = try writeAllowlist(entries: "")
        let status = try run(script: script, args: [index.path, allow.path])
        XCTAssertEqual(status, 0, "a campaign with zero findings must pass the gate trivially")
    }

    /// A real campaign always writes `index.json` (`FindingsSink.flush()`
    /// rewrites it on every run, including a clean empty one). A missing
    /// `index.json` is therefore not "no findings" — it's evidence the
    /// campaign never actually ran (e.g. the backend factory threw before a
    /// single iteration, which `fuzz-chat` currently still exits 0 for; see
    /// ManifoldKit#2367). The gate must fail loud here, not vacuously pass —
    /// a report-then-gate step chain that treats "nothing to report" as
    /// "nothing wrong" would certify a fuzz job that fuzzed nothing.
    func test_missingIndexJSON_exitsOne() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let missingIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-gate-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.json")
        let allow = try writeAllowlist(entries: "")
        let status = try run(script: script, args: [missingIndex.path, allow.path])
        XCTAssertEqual(status, 1, "a missing index.json means the campaign never ran and must fail the gate, not pass vacuously")
    }

    /// The missing-`index.json` check (above) only protects against the file
    /// being absent. A checkout with `clean: false` (the default is `true`,
    /// but nothing enforces it) could leave a STALE `index.json` from an
    /// earlier run in `tmp/fuzz/`, which the missing-file check would not
    /// catch — the file exists, it's just not from this run. Requiring
    /// `totalRuns > 0` from the index the gate actually parsed closes that
    /// gap independent of the missing-file check, and independent of
    /// `fuzz-chat`'s own exit code (`FuzzReport.exitCode(for:)`) — the gate
    /// now detects a zero-run campaign on its own evidence.
    func test_presentButZeroRunsIndexJSON_exitsOne() throws {
        guard let root = repoRoot() else { throw XCTSkip("gate script not found from test bundle location") }
        let script = root.appendingPathComponent("scripts/fuzz-ci-gate.sh")
        let index = try writeIndex(totalRuns: 0, hash: nil)
        let allow = try writeAllowlist(entries: "")
        let status = try run(script: script, args: [index.path, allow.path])
        XCTAssertEqual(status, 1, "a present index.json reporting totalRuns == 0 means the campaign never ran (possibly a stale file) and must fail the gate")
    }
}
