import Foundation
import XCTest

/// Hermetic regression coverage for `scripts/check-coverage.sh`. The fixture
/// supplies an `xcrun` shim and inert profile/binary files, so these tests run
/// the checker without rebuilding or running the package's Swift test suites.
///
/// Wave 0 showed that c27b7626 returned success for missing inputs, failed or
/// empty reports, absent module data, and malformed report rows. The valid
/// and low-coverage controls ensure the new failures are not a blanket
/// rejection; the remaining invalid-count cases extend that contract.
final class CoverageCheckScriptTests: XCTestCase {
    private enum XcrunMode {
        case available
        case unavailable
        case reportFailure
    }

    private struct Fixture {
        let root: URL
        let profile: URL
        let binary: URL
        let report: URL
        let xcrunLog: URL
        let shimDirectory: URL
    }

    private func repoRoot() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/check-coverage.sh").path) else {
            throw NSError(
                domain: "CoverageCheckScriptTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "scripts/check-coverage.sh not found from test bundle location"]
            )
        }
        return root
    }

    private func makeFixture(report: String, mode: XcrunMode = .available) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("coverage-check-fixture-\(UUID().uuidString)")
        let shimDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)

        let profile = root.appendingPathComponent("fixture.profdata")
        let binary = root.appendingPathComponent("fixture.xctest")
        let reportURL = root.appendingPathComponent("report.txt")
        let xcrunLog = root.appendingPathComponent("xcrun.log")
        try Data("profile".utf8).write(to: profile)
        try Data("binary".utf8).write(to: binary)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        let modeValue: String
        switch mode {
        case .available: modeValue = "available"
        case .unavailable: modeValue = "unavailable"
        case .reportFailure: modeValue = "report-failure"
        }
        let shim = """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$COVERAGE_XCRUN_LOG"
        if [[ "$1" == "--find" ]]; then
          [[ "\(modeValue)" == "unavailable" ]] && exit 1
          echo /fixture/llvm-cov
          exit 0
        fi
        if [[ "\(modeValue)" == "report-failure" ]]; then
          echo "fixture report failure" >&2
          exit 1
        fi
        /bin/cat "$COVERAGE_REPORT"
        """
        let xcrun = shimDirectory.appendingPathComponent("xcrun")
        try shim.write(to: xcrun, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        return Fixture(root: root, profile: profile, binary: binary, report: reportURL, xcrunLog: xcrunLog, shimDirectory: shimDirectory)
    }

    private func run(_ fixture: Fixture, profile: URL? = nil, binary: URL? = nil) throws -> (status: Int32, output: String) {
        let root = try repoRoot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = [
            "scripts/check-coverage.sh",
            "--profdata", (profile ?? fixture.profile).path,
            "--binary", (binary ?? fixture.binary).path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.shimDirectory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["COVERAGE_XCRUN_LOG"] = fixture.xcrunLog.path
        environment["COVERAGE_REPORT"] = fixture.report.path
        process.environment = environment

        // A pipe can deadlock when a failing checker emits enough diagnostics
        // to fill its buffer before `waitUntilExit()` returns. File-backed
        // capture avoids pipe-capacity deadlock without changing the process's
        // output semantics.
        let outputURL = fixture.root.appendingPathComponent("checker-output-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        let data = try Data(contentsOf: outputURL)
        try FileManager.default.removeItem(at: outputURL)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func assertShimWasUsed(_ fixture: Fixture, reportExpected: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let log = try String(contentsOf: fixture.xcrunLog, encoding: .utf8)
        XCTAssertTrue(log.contains("--find llvm-cov"), "xcrun shim was not used for llvm-cov discovery", file: file, line: line)
        XCTAssertEqual(log.contains("report"), reportExpected, "unexpected xcrun report invocation: \(log)", file: file, line: line)
    }

    private func withFixture(
        report: String,
        mode: XcrunMode = .available,
        body: (Fixture) throws -> Void
    ) throws {
        let fixture = try makeFixture(report: report, mode: mode)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(fixture)
    }

    private var allModulesAt100Percent: String {
        """
        Sources/ManifoldInference/a.swift 1 0 100% 1 0 100% 100 0 100%
        Sources/ManifoldInference/Declaration.swift 0 0 100% 0 0 100% 0 0 100%
        /private/build/Sources/ManifoldRuntime/a.swift 1 0 100% 1 0 100% 100 0 100%
        ./Sources/ManifoldPersistenceSwiftData/a.swift 1 0 100% 1 0 100% 100 0 100%
        ManifoldMCP/a.swift 1 0 100% 1 0 100% 100 0 100%
        """
    }

    func test_validMeasurementsAcrossNormalizedPathFormsPass() throws {
        try withFixture(report: allModulesAt100Percent) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("RESULT: All modules meet coverage thresholds."), result.output)
            try assertShimWasUsed(fixture, reportExpected: true)
        }
    }

    func test_completeValidLowCoverageFailsWithThresholdExit() throws {
        let low = allModulesAt100Percent.replacingOccurrences(of: "100 0 100%", with: "100 90 10%")
        try withFixture(report: low) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 1, result.output)
            XCTAssertTrue(result.output.contains("COVERAGE BELOW THRESHOLD"), result.output)
            try assertShimWasUsed(fixture, reportExpected: true)
        }
    }

    func test_roundedDisplayValueDoesNotOverrideRawThresholdCounts() throws {
        let almostThreshold = allModulesAt100Percent.replacingOccurrences(
            of: "Sources/ManifoldInference/a.swift 1 0 100% 1 0 100% 100 0 100%",
            with: "Sources/ManifoldInference/a.swift 1 0 100% 1 0 100% 2500 651 74.0%"
        )
        try withFixture(report: almostThreshold) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 1, result.output)
            XCTAssertTrue(result.output.contains("COVERAGE BELOW THRESHOLD"), result.output)
            XCTAssertNotNil(
                result.output.range(of: "ManifoldInference\\s+74\\.0%\\s+74%\\s+FAIL", options: .regularExpression),
                result.output
            )
        }
    }

    func test_missingToolAndMissingInputsAreOperationalFailures() throws {
        try withFixture(report: allModulesAt100Percent, mode: .unavailable) { fixture in
            let unavailable = try run(fixture)
            XCTAssertEqual(unavailable.status, 2, unavailable.output)
            XCTAssertTrue(unavailable.output.contains("could not locate llvm-cov"), unavailable.output)
            try assertShimWasUsed(fixture, reportExpected: false)
        }

        try withFixture(report: allModulesAt100Percent) { fixture in
            let missingProfile = try run(fixture, profile: fixture.root.appendingPathComponent("missing.profdata"))
            XCTAssertEqual(missingProfile.status, 2, missingProfile.output)
            XCTAssertTrue(missingProfile.output.contains("profdata not found"), missingProfile.output)

            let missingBinary = try run(fixture, binary: fixture.root.appendingPathComponent("missing.xctest"))
            XCTAssertEqual(missingBinary.status, 2, missingBinary.output)
            XCTAssertTrue(missingBinary.output.contains("xctest binary not found"), missingBinary.output)
        }
    }

    func test_reportFailureEmptyReportAndMissingModuleDataAreOperationalFailures() throws {
        try withFixture(report: allModulesAt100Percent, mode: .reportFailure) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("llvm-cov report failed"), result.output)
            try assertShimWasUsed(fixture, reportExpected: true)
        }

        try withFixture(report: "\n") { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("report was empty"), result.output)
        }

        let missingMCP = allModulesAt100Percent.replacingOccurrences(
            of: "ManifoldMCP/a.swift 1 0 100% 1 0 100% 100 0 100%",
            with: "Other/a.swift 1 0 100% 1 0 100% 100 0 100%"
        )
        try withFixture(report: missingMCP) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("ManifoldMCP (no report rows)"), result.output)
        }
    }

    func test_malformedAndImpossibleLineCountsAreOperationalFailures() throws {
        let malformed = allModulesAt100Percent + "\nSources/ManifoldInference/malformed.swift invalid"
        try withFixture(report: malformed) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("malformed or impossible line counts"), result.output)
        }

        let invalidRows = [
            "Sources/ManifoldInference/missed.swift 1 0 100% 1 0 100% 100 101 100%",
            "Sources/ManifoldInference/negative.swift 1 0 100% 1 0 100% -1 0 100%"
        ]
        for invalidRow in invalidRows {
            try withFixture(report: allModulesAt100Percent + "\n" + invalidRow) { fixture in
                let result = try run(fixture)
                XCTAssertEqual(result.status, 2, "\(invalidRow): \(result.output)")
                XCTAssertTrue(result.output.contains("malformed or impossible line counts"), result.output)
            }
        }

        let zeroTotalModule = allModulesAt100Percent.replacingOccurrences(
            of: "/private/build/Sources/ManifoldRuntime/a.swift 1 0 100% 1 0 100% 100 0 100%",
            with: "/private/build/Sources/ManifoldRuntime/a.swift 0 0 100% 0 0 100% 0 0 100%"
        )
        try withFixture(report: zeroTotalModule) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("malformed or impossible line counts"), result.output)
        }

        let hugeCounts = allModulesAt100Percent + "\nSources/ManifoldInference/huge.swift 1 0 100% 1 0 100% 200000000000000000 200000000000000000 0%"
        try withFixture(report: hugeCounts) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("malformed or impossible line counts"), result.output)
        }

        let oversizedAggregate = allModulesAt100Percent + """
        
        Sources/ManifoldInference/large-a.swift 1 0 100% 1 0 100% 2000000000 0 100%
        Sources/ManifoldInference/large-b.swift 1 0 100% 1 0 100% 2000000000 0 100%
        """
        try withFixture(report: oversizedAggregate) { fixture in
            let result = try run(fixture)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertTrue(result.output.contains("malformed or impossible line counts"), result.output)
        }
    }
}
