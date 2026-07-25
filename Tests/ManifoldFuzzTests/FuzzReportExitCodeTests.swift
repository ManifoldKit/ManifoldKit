import XCTest
@testable import ManifoldFuzz

/// Unit coverage for `FuzzReport.exitCode(for:)` — the pure function
/// `fuzz-chat`'s CLI now delegates its process exit code to (ManifoldKit
/// #2367 review). Extracted specifically so this decision is testable
/// without spawning the `fuzz-chat` executable: `exit(_:)` terminates the
/// hosting process, so a `Process()`-based CLI test would need to build and
/// launch the real binary with a fixture engineered to make
/// `FuzzBackendFactory.makeHandle()` throw before the first iteration — real
/// scope this repo has no existing pattern for. The logic that could
/// plausibly be wrong (the boolean decision) is what's covered here; handing
/// an `Int32` to `exit(_:)` is not.
///
/// Covers the reachable combinations of (`isInert`, `totalRuns == 0`):
///   - totalRuns == 0 (the campaign never started — #2367's gap)   → exit 1
///   - totalRuns > 0, realCompletions == 0 (isInert — #2344's gap) → exit 1
///   - totalRuns > 0, realCompletions > 0 but < totalRuns          → exit 0
///   - totalRuns > 0, realCompletions == totalRuns (fully healthy) → exit 0
/// `isInert == true && totalRuns == 0` is not covered because it is
/// unreachable by construction: `isInert`'s own definition requires
/// `totalRuns > 0`, so no real `FuzzReport` can have both.
final class FuzzReportExitCodeTests: XCTestCase {

    private func report(totalRuns: Int, realCompletions: Int) -> FuzzReport {
        FuzzReport(
            totalRuns: totalRuns,
            findings: [],
            dedupedCount: 0,
            perDetectorFlagRate: [:],
            realCompletions: realCompletions
        )
    }

    func test_zeroRuns_exitsOne() {
        // The exact #2367 gap: factory.makeHandle() threw before the loop
        // started, so isInert is false (it requires totalRuns > 0) but the
        // campaign still never ran a single iteration.
        let r = report(totalRuns: 0, realCompletions: 0)
        XCTAssertFalse(r.isInert, "precondition: isInert must NOT catch this case on its own — that's the bug being fixed")
        XCTAssertEqual(FuzzReport.exitCode(for: r), 1, "a campaign that never ran must exit 1, not 0")
    }

    func test_inertCampaign_exitsOne() {
        // The pre-existing #2344 case: ran, but not one turn completed for real.
        let r = report(totalRuns: 5, realCompletions: 0)
        XCTAssertTrue(r.isInert)
        XCTAssertEqual(FuzzReport.exitCode(for: r), 1, "an inert campaign must exit 1")
    }

    func test_partiallyHealthyCampaign_exitsZero() {
        let r = report(totalRuns: 5, realCompletions: 3)
        XCTAssertFalse(r.isInert)
        XCTAssertEqual(FuzzReport.exitCode(for: r), 0, "a campaign that drove some real completions must exit 0")
    }

    func test_fullyHealthyCampaign_exitsZero() {
        let r = report(totalRuns: 5, realCompletions: 30)
        XCTAssertFalse(r.isInert)
        XCTAssertEqual(FuzzReport.exitCode(for: r), 0, "a fully healthy campaign must exit 0")
    }

    // MARK: - Sabotage

    /// Demonstrates this test suite can actually tell correct from broken by
    /// running the OLD, pre-#2367 logic (isInert alone) against the same
    /// zero-run fixture `test_zeroRuns_exitsOne` uses, and confirming it
    /// would have wrongly returned 0 — the exact silent-pass this PR fixes.
    func test_sabotage_isInertAloneWouldMissTheZeroRunCase() {
        let r = report(totalRuns: 0, realCompletions: 0)
        let oldNaiveExitCode: Int32 = r.isInert ? 1 : 0
        XCTAssertEqual(oldNaiveExitCode, 0, "sabotage precondition: the pre-fix logic must reproduce the bug (exit 0) on this fixture")
        XCTAssertNotEqual(
            oldNaiveExitCode, FuzzReport.exitCode(for: r),
            "the fixed exitCode(for:) must diverge from the old isInert-only logic on the zero-run case — " +
            "if this assertion ever passes with equal values, exitCode(for:) has regressed back to the #2367 bug"
        )
    }
}
