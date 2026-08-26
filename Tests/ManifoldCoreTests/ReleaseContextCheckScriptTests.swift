import XCTest

/// Regression coverage for the exact strict-SemVer comparator that lint.yml
/// uses before it enables the release-only gates. A workflow-only test would
/// go green on an older-but-unequal version, which is the false positive this
/// helper was introduced to prevent.
final class ReleaseContextCheckScriptTests: XCTestCase {

    private func repoRoot() -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/release-context-check.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return candidate
    }

    private func run(_ args: [String]) throws -> (status: Int32, output: String) {
        guard let root = repoRoot() else {
            throw XCTSkip("release-context-check.sh not found from test bundle location")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-context-check-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/release-context-check.sh").path] + args
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func test_strictSemVerComparison_acceptsOnlyNewerVersions() throws {
        let older = try run(["--is-strictly-greater", "0.76.0", "0.76.1"])
        XCTAssertEqual(older.status, 0, "older comparison must execute: \(older.output)")
        XCTAssertEqual(older.output.trimmingCharacters(in: .whitespacesAndNewlines), "false")

        let equal = try run(["--is-strictly-greater", "0.76.1", "0.76.1"])
        XCTAssertEqual(equal.status, 0, "equal comparison must execute: \(equal.output)")
        XCTAssertEqual(equal.output.trimmingCharacters(in: .whitespacesAndNewlines), "false")

        let newer = try run(["--is-strictly-greater", "0.77.0", "0.76.1"])
        XCTAssertEqual(newer.status, 0, "newer comparison must execute: \(newer.output)")
        XCTAssertEqual(newer.output.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    func test_strictSemVerComparison_handlesPrereleasePrecedence() throws {
        let stableOverPrerelease = try run(["--is-strictly-greater", "1.0.0", "1.0.0-rc.1"])
        XCTAssertEqual(stableOverPrerelease.status, 0, "prerelease comparison must execute: \(stableOverPrerelease.output)")
        XCTAssertEqual(stableOverPrerelease.output.trimmingCharacters(in: .whitespacesAndNewlines), "true")

        let olderPrerelease = try run(["--is-strictly-greater", "1.0.0-rc.1", "1.0.0"])
        XCTAssertEqual(olderPrerelease.status, 0, "prerelease comparison must execute: \(olderPrerelease.output)")
        XCTAssertEqual(olderPrerelease.output.trimmingCharacters(in: .whitespacesAndNewlines), "false")
    }

    func test_strictSemVerComparison_rejectsMalformedValuesFailClosed() throws {
        for malformed in ["0.76", "v0.76.2", "01.76.2", "0.76.2-01"] {
            let result = try run(["--is-strictly-greater", malformed, "0.76.1"])
            XCTAssertEqual(result.status, 2, "malformed current version \(malformed) must fail closed: \(result.output)")
            XCTAssertTrue(result.output.contains("Invalid strict SemVer"), "expected named failure, got: \(result.output)")
        }

        let malformedLatest = try run(["--is-strictly-greater", "0.76.2", "v0.76.1"])
        XCTAssertEqual(malformedLatest.status, 2, "malformed latest version must fail closed: \(malformedLatest.output)")
        XCTAssertTrue(
            malformedLatest.output.contains("Invalid strict SemVer"),
            "expected named malformed-latest failure, got: \(malformedLatest.output)"
        )
    }
}
