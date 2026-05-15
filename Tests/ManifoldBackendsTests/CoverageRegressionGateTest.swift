import XCTest

/// Phase 1a guard: pins region coverage of `Sources/ManifoldCloud/**` and
/// `Sources/ManifoldInference/**` against a baseline snapshot under
/// `Tests/Fixtures/_migration/baseline-coverage.json`.
///
/// Why it exists: the cross-backend unification plan will rewrite OpenAI /
/// Claude / Ollama / Responses through a shared `CloudHTTPProviderAdapter`.
/// Each migration phase deliberately deletes per-backend parser tests and
/// replaces them with a single parameterized contract suite. Without a
/// coverage baseline, a refactor that loses test density can ship green.
///
/// ## Skip semantics
///
/// When the baseline JSON is absent (the file has not yet been captured),
/// the test logs the reason and skips rather than failing. This lets the
/// gate land in a PR before the baseline-capture step has been run on a
/// canonical runner.
///
/// ## Failure modes
///
/// 1. Any file present in the baseline drops more than `0.5` percentage
///    points below its baseline region-coverage percentage.
/// 2. Any file that had non-zero baseline coverage drops to `0.0` percent
///    (treated as a categorical regression — likely a deleted test).
///
/// The baseline JSON shape:
/// ```json
/// {
///   "captured_at": "2026-05-15T...Z",
///   "swift_version": "6.2.x",
///   "files": {
///     "Sources/ManifoldCloud/OpenAIBackend.swift": { "regions_pct": 78.4 }
///   }
/// }
/// ```
///
/// A separate runner step writes this file via `xccov view --json` or by
/// running the suite under `swift test --enable-code-coverage` and
/// projecting the result with `scripts/coverage/snapshot.sh` (planned for
/// Phase 1b once the baseline format proves out in practice).
final class CoverageRegressionGateTest: XCTestCase {

    private static let regressionToleranceP: Double = 0.5

    private struct Baseline: Decodable {
        let files: [String: FileEntry]
        struct FileEntry: Decodable { let regions_pct: Double }
    }

    func test_coverageHasNotRegressedBeyondTolerance() throws {
        let baselineURL = try Self.locateMigrationFixture(named: "baseline-coverage.json")
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            // Skip rather than fail — the test ships before the first
            // baseline capture, so an absent file is the expected state
            // until Phase 1b runs the snapshotting tool.
            try XCTSkipIf(true, """
                SKIPPED: \(baselineURL.path) does not exist. The coverage \
                baseline has not been captured yet. Run a coverage pass and \
                drop the snapshot into Tests/Fixtures/_migration/ before this \
                gate becomes active.
                """)
            return
        }

        let data = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(Baseline.self, from: data)

        // The "current" coverage measurement is supplied through an
        // environment variable populated by the CI driver that runs the
        // suite under `swift test --enable-code-coverage` and pipes the
        // result through xccov. When the env var is absent, we cannot
        // compare and skip with a non-failing log so the gate doesn't
        // fail on every local run.
        let env = ProcessInfo.processInfo.environment
        guard let currentJSON = env["COVERAGE_SNAPSHOT_JSON"], !currentJSON.isEmpty else {
            try XCTSkipIf(true, """
                SKIPPED: COVERAGE_SNAPSHOT_JSON env var not set. The CI driver \
                must populate this with the current run's coverage JSON for \
                the gate to compare against the baseline. Local runs skip.
                """)
            return
        }

        guard let currentData = currentJSON.data(using: .utf8),
              let current = try? JSONDecoder().decode(Baseline.self, from: currentData) else {
            XCTFail("COVERAGE_SNAPSHOT_JSON was set but did not parse as the baseline JSON shape")
            return
        }

        var regressions: [String] = []
        for (path, baselineEntry) in baseline.files {
            guard let currentEntry = current.files[path] else {
                regressions.append("\(path): missing from current snapshot (file deleted? coverage step skipped it?)")
                continue
            }
            let drop = baselineEntry.regions_pct - currentEntry.regions_pct
            if drop > Self.regressionToleranceP {
                regressions.append(
                    "\(path): \(baselineEntry.regions_pct)% → \(currentEntry.regions_pct)% (drop \(drop)pp > tolerance \(Self.regressionToleranceP)pp)"
                )
            }
            if baselineEntry.regions_pct > 0.0 && currentEntry.regions_pct == 0.0 {
                regressions.append(
                    "\(path): coverage collapsed to 0% (was \(baselineEntry.regions_pct)%) — likely the test exercising it was deleted without a replacement"
                )
            }
        }

        if regressions.isEmpty { return }
        XCTFail("""
            CoverageRegressionGateTest found regressions:

              \(regressions.joined(separator: "\n  "))

            Fix:
              - If the drop is intentional (e.g. a file was simplified and the lost regions were dead code), update the baseline:
                  swift package update-coverage-baseline       # planned in Phase 1b
              - Otherwise, restore the missing coverage in the same PR.
            """)
    }

    // MARK: - Helpers

    private static func locateMigrationFixture(named: String, filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/_migration/\(named)")
            if FileManager.default.fileExists(atPath: candidate.deletingLastPathComponent().path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "CoverageRegressionGateTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/_migration/ from #filePath"
        ])
    }
}
