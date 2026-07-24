import XCTest

/// Coarse wall-clock ceilings for the measure-only performance suites.
///
/// `XCTMeasure` under `swift test` records timings but has no committed
/// baselines and never fails on regression — a 10× slowdown in a hot path
/// stays green, which makes those suites fail-open perf coverage. These
/// helpers add the assertion a regression cannot satisfy: one timed run
/// compared against a deliberately generous budget (hundreds of times the
/// observed average, so CI-runner slowness and cold-start noise never trip
/// it; only a real order-of-magnitude regression does).
///
/// Budget discipline: a blown budget is a finding, not an inconvenience —
/// investigate the regression before considering raising the number.
enum PerfBudget {

    /// Asserts `work` completes within `budget` (single run, wall clock).
    static func assert(
        _ budget: Duration,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () throws -> Void
    ) rethrows {
        let elapsed = try ContinuousClock().measure(work)
        XCTAssertLessThan(
            elapsed, budget,
            "Performance budget blown — an order-of-magnitude regression, not CI noise. Investigate before raising the budget.",
            file: file, line: line
        )
    }

    /// Async variant of ``assert(_:file:line:_:)``.
    static func assertAsync(
        _ budget: Duration,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () async throws -> Void
    ) async rethrows {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        let elapsed = clock.now - start
        XCTAssertLessThan(
            elapsed, budget,
            "Performance budget blown — an order-of-magnitude regression, not CI noise. Investigate before raising the budget.",
            file: file, line: line
        )
    }
}

/// Proves the budget guard can go red — a ceiling that cannot fail is not
/// a ceiling. (The same demonstrated-failure discipline the audit tests
/// follow via `test_sabotage_*`.)
final class PerfBudgetProofTests: XCTestCase {

    func test_blownBudget_failsTheTest() {
        XCTExpectFailure("A blown budget must fail — this proves the guard fires.") {
            PerfBudget.assert(.nanoseconds(1)) {
                var accumulator = 0.0
                for i in 1...1_000_000 {
                    accumulator += Double(i).squareRoot()
                }
                XCTAssertGreaterThan(accumulator, 0)
            }
        }
    }

    func test_metBudget_passes() {
        PerfBudget.assert(.seconds(10)) {
            _ = (1...100).reduce(0, +)
        }
    }

    func test_blownAsyncBudget_failsTheTest() async {
        await XCTExpectFailureAsync("A blown async budget must fail — proves the async guard fires.") {
            await PerfBudget.assertAsync(.nanoseconds(1)) {
                var accumulator = 0.0
                for i in 1...1_000_000 {
                    accumulator += Double(i).squareRoot()
                }
                XCTAssertGreaterThan(accumulator, 0)
            }
        }
    }
}

/// `XCTExpectFailure` has no async-closure overload; wrap the options-based
/// form around an awaited body instead.
private func XCTExpectFailureAsync(
    _ failureReason: String,
    _ body: () async -> Void
) async {
    let options = XCTExpectedFailure.Options()
    options.issueMatcher = { _ in true }
    XCTExpectFailure(failureReason, options: options)
    await body()
}
