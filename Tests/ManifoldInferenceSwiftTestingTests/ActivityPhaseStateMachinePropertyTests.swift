import Testing
import Foundation
@testable import ManifoldInference

/// Property-based stress tests for ``ActivityPhaseStateMachine``. A
/// deterministic-but-seeded PRNG generates sequences of pseudo-random
/// events and feeds them into the machine. The invariants asserted are:
///
/// 1. The machine never panics or diverges — rejected transitions leave
///    the phase unchanged.
/// 2. `phase` after every step must always be one of the known cases.
/// 3. Any transition the machine accepts must also satisfy
///    ``ActivityPhaseStateMachine/isLegalTransition(from:to:)``, so the
///    static predicate and the mutating apply stay in lock-step.
@Suite("ActivityPhaseStateMachine property tests")
struct ActivityPhaseStateMachinePropertyTests {

    /// The machine accepts `BackendActivityPhase` targets directly.
    /// We model an "event" as a candidate target drawn from the full
    /// phase vocabulary — this is denser and more stressing than a
    /// narrow event alphabet, because it forces the machine to deal
    /// with genuinely arbitrary sequences.
    private static let candidates: [BackendActivityPhase] = [
        .idle,
        .modelLoading(progress: nil),
        .modelLoading(progress: 0.25),
        .modelLoading(progress: 0.75),
        .waitingForFirstToken,
        .streaming,
        .stalled,
        .retrying(attempt: 1, of: 3),
        .retrying(attempt: 2, of: 3),
        .retrying(attempt: 3, of: 3)
    ]

    /// 128 seeded sequences (>=100 required by the issue). Each seed
    /// is the test argument, so failures print the exact seed and are
    /// trivially reproducible.
    @Test(
        "Random event sequences never drive the machine into an inconsistent state",
        arguments: Array(0..<128)
    )
    func randomSequenceRespectsInvariants(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        var machine = ActivityPhaseStateMachine()

        for _ in 0..<64 {
            let from = machine.phase
            let candidate = Self.candidates.randomElement(using: &rng)!
            let result = machine.transition(to: candidate)

            switch result {
            case .applied, .unchanged:
                // Accepted: either the transition was legal per the
                // static predicate OR it was a same-case progress
                // update (which the predicate also reports as legal).
                #expect(
                    ActivityPhaseStateMachine.isLegalTransition(
                        from: from,
                        to: candidate
                    ),
                    "Machine accepted \(from) → \(candidate) but static predicate disagreed (seed \(seed))"
                )
            case .rejected(let rFrom, let rTo):
                // Rejected: phase must not have moved.
                #expect(
                    machine.phase == from,
                    "Rejected transition should not mutate phase (seed \(seed))"
                )
                #expect(rFrom == from)
                #expect(rTo == candidate)
            }
        }
    }

    /// Idle and modelLoading are the universal escapes — every
    /// reachable phase must accept them. We drive the machine through
    /// random sequences and then prove that from wherever it lands,
    /// cancel (`.idle`) and model-swap (`.modelLoading`) always work.
    @Test(
        "Idle and modelLoading are always reachable from any random walk endpoint",
        arguments: Array(0..<128)
    )
    func universalEscapesAlwaysWork(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed) ^ 0xDEADBEEF)
        var machine = ActivityPhaseStateMachine()

        for _ in 0..<32 {
            let candidate = Self.candidates.randomElement(using: &rng)!
            _ = machine.transition(to: candidate)
        }

        // From wherever we ended up, cancelling to idle must succeed.
        var cancelMachine = machine
        let cancelResult = cancelMachine.transition(to: .idle)
        #expect(
            cancelResult != .rejected(from: machine.phase, to: .idle),
            "Cancel should never be rejected (seed \(seed), landed in \(machine.phase))"
        )

        // And swapping to a new model must also succeed.
        var swapMachine = machine
        let swapResult = swapMachine.transition(to: .modelLoading(progress: nil))
        #expect(
            swapResult != .rejected(
                from: machine.phase,
                to: .modelLoading(progress: nil)
            ),
            "Model swap should never be rejected (seed \(seed), landed in \(machine.phase))"
        )
    }
}

// MARK: - Seeded RNG
//
// Swift Testing + Foundation's `SystemRandomNumberGenerator` would give
// us non-deterministic sequences — if a property fails in CI we'd have
// no way to reproduce it locally. A tiny splitmix64 keeps each seed
// independent and cheap.

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
