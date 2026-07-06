/// An async permit gate that lets a test/scenario driver release scripted
/// events one at a time, making "cancel after observing exactly N events"
/// deterministic rather than racing an unbounded stream buffer.
///
/// This is ManifoldAppEval's own copy of the same small primitive
/// `ManifoldTestSupport.TokenEmissionGate` provides for `MockInferenceBackend`.
/// It is duplicated — not shared — because ManifoldAppEval deliberately
/// carries no dependency edge onto `ManifoldTestSupport` (see the module's
/// DocC boundary statement), and the type is trivial (~25 lines, no
/// dependencies of its own). Named distinctly (`AppEvalTokenEmissionGate`
/// rather than `TokenEmissionGate`) so files that import both modules — several
/// of MK's own test targets do, since `ManifoldTestSupport`'s `MockInferenceBackend`
/// and this module's `ScriptedGenerationBackend` are both in play — never hit an
/// ambiguous-lookup error.
///
/// ## Usage
/// ```swift,no-build
/// let gate = AppEvalTokenEmissionGate()
/// backend.tokenEmissionGate = gate
/// // ... start generation ...
/// await gate.advance() // release exactly one token
/// ```
public actor AppEvalTokenEmissionGate {
    private var pendingPermits: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Suspends the caller until ``advance()`` issues a permit.
    public func waitForAdvance() async {
        if pendingPermits > 0 {
            pendingPermits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// Issues one permit. If a waiter is already suspended, resumes it;
    /// otherwise the permit is buffered for the next ``waitForAdvance()``.
    public func advance() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            pendingPermits += 1
        }
    }
}
