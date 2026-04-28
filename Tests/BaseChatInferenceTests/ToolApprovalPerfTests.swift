import XCTest
@testable import BaseChatInference

/// Regression guard for the ``AutoApproveGate`` hot path.
///
/// This is not a micro-benchmark — the budget is deliberately generous
/// (500 ms for 1000 sequential approvals). The purpose is to catch a
/// future regression that accidentally adds heavy work (I/O, logging, an
/// actor hop) into ``AutoApproveGate/approve(_:)``. The gate is invoked
/// once per ``ToolCall`` inside the generation loop, so any non-trivial
/// overhead compounds across long agentic runs.
@MainActor
final class ToolApprovalPerfTests: XCTestCase {

    func testPerf_autoApprove_thousandCalls() {
        let gate = AutoApproveGate()
        // Pre-build the calls outside `measure { }` so the harness only
        // times the gate invocations themselves, not fixture setup. Per
        // CLAUDE.md perf guidelines, all fixtures must be ready before the
        // measure block.
        let calls: [ToolCall] = (0..<1000).map { idx in
            ToolCall(
                id: "c-\(idx)",
                toolName: "noop",
                arguments: #"{"i":\#(idx)}"#
            )
        }

        measure {
            let clock = ContinuousClock()
            let start = clock.now

            // Run the approval loop synchronously via a blocking task so
            // `measure { }` can time it. `AutoApproveGate.approve` is an
            // `async` method but never suspends, so this completes
            // eagerly on the current actor.
            let expectation = expectation(description: "approvals complete")
            Task { @MainActor in
                for call in calls {
                    _ = await gate.approve(call)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 5.0)

            let elapsed = clock.now - start
            // Generous headroom — 500 ms for 1000 calls is ~500 µs/call,
            // well above what the direct enum return should ever take.
            // This surfaces regressions like an accidental log call or
            // lock acquisition without tripping on CI jitter.
            XCTAssertLessThan(
                elapsed,
                .milliseconds(500),
                "AutoApproveGate hot path regressed: \(elapsed) for 1000 calls"
            )
        }
    }
}
