import XCTest
@testable import ManifoldInference

/// Exhaustively verifies the legal-transition graph for
/// ``ActivityPhaseStateMachine``. Every `(from, to)` pair is asserted
/// explicitly so a behaviour change forces a test update — no implicit
/// "default rule" means "legal".
final class ActivityPhaseStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    /// Canonical representatives of each phase case. Associated values
    /// are fixed so we test the shape of the transition graph, not the
    /// specifics of progress values or retry attempts.
    private let allPhases: [BackendActivityPhase] = [
        .idle,
        .modelLoading(progress: 0.0),
        .waitingForFirstToken,
        .streaming,
        .stalled,
        .retrying(attempt: 1, of: 3)
    ]

    // MARK: - Initial State

    func test_initialPhase_isIdle() {
        let machine = ActivityPhaseStateMachine()
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_initialPhase_customisable() {
        let machine = ActivityPhaseStateMachine(phase: .streaming)
        XCTAssertEqual(machine.phase, .streaming)
    }

    // MARK: - Legal transitions (exhaustive)

    func test_idle_to_modelLoading_legal() {
        assertLegal(.idle, .modelLoading(progress: nil))
    }

    func test_idle_to_waitingForFirstToken_legal() {
        assertLegal(.idle, .waitingForFirstToken)
    }

    func test_modelLoading_to_idle_legal() {
        assertLegal(.modelLoading(progress: 0.5), .idle)
    }

    func test_modelLoading_to_waitingForFirstToken_legal() {
        // Rare race: a queued send runs the instant a load completes,
        // before the load bridge flips to .idle.
        assertLegal(.modelLoading(progress: 1.0), .waitingForFirstToken)
    }

    func test_modelLoading_progressUpdate_legal() {
        var machine = ActivityPhaseStateMachine(phase: .modelLoading(progress: 0.1))
        XCTAssertEqual(
            machine.transition(to: .modelLoading(progress: 0.5)),
            .applied
        )
        XCTAssertEqual(machine.phase, .modelLoading(progress: 0.5))
    }

    func test_waitingForFirstToken_to_streaming_legal() {
        assertLegal(.waitingForFirstToken, .streaming)
    }

    func test_waitingForFirstToken_to_idle_legal() {
        assertLegal(.waitingForFirstToken, .idle)
    }

    func test_waitingForFirstToken_to_modelLoading_legal() {
        assertLegal(.waitingForFirstToken, .modelLoading(progress: nil))
    }

    func test_waitingForFirstToken_to_stalled_legal() {
        assertLegal(.waitingForFirstToken, .stalled)
    }

    func test_waitingForFirstToken_to_retrying_legal() {
        assertLegal(.waitingForFirstToken, .retrying(attempt: 1, of: 3))
    }

    func test_streaming_to_idle_legal() {
        assertLegal(.streaming, .idle)
    }

    func test_streaming_to_modelLoading_legal() {
        assertLegal(.streaming, .modelLoading(progress: nil))
    }

    func test_streaming_to_stalled_legal() {
        assertLegal(.streaming, .stalled)
    }

    func test_streaming_to_retrying_legal() {
        assertLegal(.streaming, .retrying(attempt: 1, of: 3))
    }

    func test_stalled_to_streaming_legal() {
        assertLegal(.stalled, .streaming)
    }

    func test_stalled_to_waitingForFirstToken_legal() {
        assertLegal(.stalled, .waitingForFirstToken)
    }

    func test_stalled_to_idle_legal() {
        assertLegal(.stalled, .idle)
    }

    func test_stalled_to_modelLoading_legal() {
        assertLegal(.stalled, .modelLoading(progress: nil))
    }

    func test_stalled_to_retrying_legal() {
        assertLegal(.stalled, .retrying(attempt: 1, of: 3))
    }

    func test_retrying_to_streaming_legal() {
        assertLegal(.retrying(attempt: 2, of: 3), .streaming)
    }

    func test_retrying_to_waitingForFirstToken_legal() {
        assertLegal(.retrying(attempt: 2, of: 3), .waitingForFirstToken)
    }

    func test_retrying_to_stalled_legal() {
        assertLegal(.retrying(attempt: 2, of: 3), .stalled)
    }

    func test_retrying_to_idle_legal() {
        assertLegal(.retrying(attempt: 3, of: 3), .idle)
    }

    func test_retrying_to_modelLoading_legal() {
        assertLegal(.retrying(attempt: 2, of: 3), .modelLoading(progress: nil))
    }

    func test_retrying_attemptBump_legal() {
        var machine = ActivityPhaseStateMachine(phase: .retrying(attempt: 1, of: 3))
        XCTAssertEqual(
            machine.transition(to: .retrying(attempt: 2, of: 3)),
            .applied
        )
        XCTAssertEqual(machine.phase, .retrying(attempt: 2, of: 3))
    }

    // MARK: - Universal transitions

    func test_anyPhase_toIdle_legal() {
        for from in allPhases {
            XCTAssertTrue(
                ActivityPhaseStateMachine.isLegalTransition(from: from, to: .idle),
                "\(from) → .idle should always be legal (cancel/reset path)"
            )
        }
    }

    func test_anyPhase_toModelLoading_legal() {
        for from in allPhases {
            XCTAssertTrue(
                ActivityPhaseStateMachine.isLegalTransition(
                    from: from,
                    to: .modelLoading(progress: nil)
                ),
                "\(from) → .modelLoading should always be legal (model swap path)"
            )
        }
    }

    // MARK: - Illegal transitions

    func test_idle_to_streaming_illegal() {
        assertIllegal(.idle, .streaming)
    }

    func test_idle_to_stalled_illegal() {
        assertIllegal(.idle, .stalled)
    }

    func test_idle_to_retrying_illegal() {
        assertIllegal(.idle, .retrying(attempt: 1, of: 3))
    }

    func test_modelLoading_to_streaming_illegal() {
        // Must go through waitingForFirstToken first.
        assertIllegal(.modelLoading(progress: 1.0), .streaming)
    }

    func test_modelLoading_to_stalled_illegal() {
        assertIllegal(.modelLoading(progress: 0.5), .stalled)
    }

    func test_modelLoading_to_retrying_illegal() {
        assertIllegal(.modelLoading(progress: 0.5), .retrying(attempt: 1, of: 3))
    }

    func test_streaming_to_waitingForFirstToken_illegal() {
        // Once tokens are flowing, there is no backwards path to "waiting".
        assertIllegal(.streaming, .waitingForFirstToken)
    }

    // MARK: - Rejected transitions don't mutate state

    func test_rejectedTransition_leavesPhaseUnchanged() {
        var machine = ActivityPhaseStateMachine(phase: .idle)
        let result = machine.transition(to: .streaming)
        guard case .rejected = result else {
            XCTFail("Expected rejected, got \(result)")
            return
        }
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_samePhaseSameValue_isUnchanged() {
        var machine = ActivityPhaseStateMachine(phase: .streaming)
        XCTAssertEqual(machine.transition(to: .streaming), .unchanged)
    }

    func test_idle_to_idle_unchanged() {
        var machine = ActivityPhaseStateMachine(phase: .idle)
        XCTAssertEqual(machine.transition(to: .idle), .unchanged)
    }

    func test_waitingForFirstToken_to_waitingForFirstToken_unchanged() {
        var machine = ActivityPhaseStateMachine(phase: .waitingForFirstToken)
        XCTAssertEqual(machine.transition(to: .waitingForFirstToken), .unchanged)
    }

    func test_stalled_to_stalled_unchanged() {
        var machine = ActivityPhaseStateMachine(phase: .stalled)
        XCTAssertEqual(machine.transition(to: .stalled), .unchanged)
    }

    // MARK: - Exhaustive matrix
    //
    // Mechanical backstop for the header invariant: every (from, to) pair
    // must match the table below. If a transition is added or removed
    // without updating this table the test fails loudly, which forces the
    // author to also update the named per-pair tests above.

    func test_exhaustiveTransitionMatrix() {
        // Legal cross-pairs. Same-case pairs are handled separately by the
        // `unchanged` tests and are not listed here.
        let legalCrossPairs: Set<Pair> = [
            Pair(.idle, .modelLoading),
            Pair(.idle, .waitingForFirstToken),
            Pair(.modelLoading, .idle),
            Pair(.modelLoading, .waitingForFirstToken),
            Pair(.waitingForFirstToken, .idle),
            Pair(.waitingForFirstToken, .modelLoading),
            Pair(.waitingForFirstToken, .streaming),
            Pair(.waitingForFirstToken, .stalled),
            Pair(.waitingForFirstToken, .retrying),
            Pair(.streaming, .idle),
            Pair(.streaming, .modelLoading),
            Pair(.streaming, .stalled),
            Pair(.streaming, .retrying),
            Pair(.stalled, .idle),
            Pair(.stalled, .modelLoading),
            Pair(.stalled, .waitingForFirstToken),
            Pair(.stalled, .streaming),
            Pair(.stalled, .retrying),
            Pair(.retrying, .idle),
            Pair(.retrying, .modelLoading),
            Pair(.retrying, .waitingForFirstToken),
            Pair(.retrying, .streaming),
            Pair(.retrying, .stalled),
        ]

        for fromKind in PhaseKind.allCases {
            for toKind in PhaseKind.allCases {
                let from = fromKind.representative
                let to = toKind.representative
                let expectedLegal: Bool
                if fromKind == toKind {
                    // Same-case pairs are always "legal" in the sense that
                    // `transition(to:)` accepts them (as .applied or
                    // .unchanged). They're exercised by the named
                    // `_unchanged` tests.
                    expectedLegal = true
                } else {
                    expectedLegal = legalCrossPairs.contains(Pair(fromKind, toKind))
                }
                let actualLegal = ActivityPhaseStateMachine.isLegalTransition(
                    from: from, to: to
                )
                XCTAssertEqual(
                    actualLegal,
                    expectedLegal,
                    "\(fromKind) → \(toKind): expected legal=\(expectedLegal), got \(actualLegal)"
                )
            }
        }
    }

    private enum PhaseKind: CaseIterable, Hashable {
        case idle, modelLoading, waitingForFirstToken, streaming, stalled, retrying
        var representative: BackendActivityPhase {
            switch self {
            case .idle: return .idle
            case .modelLoading: return .modelLoading(progress: 0.5)
            case .waitingForFirstToken: return .waitingForFirstToken
            case .streaming: return .streaming
            case .stalled: return .stalled
            case .retrying: return .retrying(attempt: 1, of: 3)
            }
        }
    }

    private struct Pair: Hashable {
        let from: PhaseKind
        let to: PhaseKind
        init(_ from: PhaseKind, _ to: PhaseKind) {
            self.from = from
            self.to = to
        }
    }

    // MARK: - Race regression scenarios
    //
    // Each scenario below reproduces one of the four race conditions
    // called out in issue #240's "Root cause 4" audit finding. The
    // state machine must either accept the sequence without diverging
    // or reject obviously-wrong events cleanly.

    func test_race_modelLoadFailsWhileUserTyping_thenSendTapped() {
        // User types → load fails → user taps send without reloading.
        // The machine is in .idle (load bridge transitioned it on
        // failure), so sendRequested → waitingForFirstToken is legal.
        var machine = ActivityPhaseStateMachine(phase: .idle)
        _ = machine.transition(to: .modelLoading(progress: 0.2))
        _ = machine.transition(to: .idle) // load failed
        XCTAssertEqual(machine.transition(to: .waitingForFirstToken), .applied)
    }

    func test_race_modelSwitchMidStream() {
        // User is mid-stream, switches models. Model swap must be legal
        // from every active phase.
        var machine = ActivityPhaseStateMachine(phase: .streaming)
        XCTAssertEqual(
            machine.transition(to: .modelLoading(progress: nil)),
            .applied
        )
        // After the new load completes, generation must be able to
        // start fresh.
        _ = machine.transition(to: .idle)
        XCTAssertEqual(machine.transition(to: .waitingForFirstToken), .applied)
    }

    func test_race_rapidSendCancelSendCancelSend() {
        var machine = ActivityPhaseStateMachine(phase: .idle)
        for _ in 0..<3 {
            XCTAssertEqual(machine.transition(to: .waitingForFirstToken), .applied)
            XCTAssertEqual(machine.transition(to: .idle), .applied)
        }
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_race_scenePhaseBackground_whileStreaming() {
        // App backgrounds mid-stream. The VM emits cancel → idle.
        // Returning foreground, the user can start a new generation.
        var machine = ActivityPhaseStateMachine(phase: .streaming)
        XCTAssertEqual(machine.transition(to: .idle), .applied)
        XCTAssertEqual(machine.transition(to: .waitingForFirstToken), .applied)
    }

    // MARK: - Helpers

    private func assertLegal(
        _ from: BackendActivityPhase,
        _ to: BackendActivityPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            ActivityPhaseStateMachine.isLegalTransition(from: from, to: to),
            "Expected \(from) → \(to) to be legal",
            file: file,
            line: line
        )
        var machine = ActivityPhaseStateMachine(phase: from)
        let result = machine.transition(to: to)
        XCTAssertNotEqual(
            result,
            .rejected(from: from, to: to),
            "transition(to:) rejected \(from) → \(to)",
            file: file,
            line: line
        )
    }

    private func assertIllegal(
        _ from: BackendActivityPhase,
        _ to: BackendActivityPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            ActivityPhaseStateMachine.isLegalTransition(from: from, to: to),
            "Expected \(from) → \(to) to be illegal",
            file: file,
            line: line
        )
        var machine = ActivityPhaseStateMachine(phase: from)
        let result = machine.transition(to: to)
        guard case .rejected = result else {
            XCTFail(
                "Expected rejected for \(from) → \(to), got \(result)",
                file: file,
                line: line
            )
            return
        }
    }
}
