import Foundation

/// `FuzzBackendFactory` that round-robins through a fixed list of child factories,
/// advancing through them in fixed-size *blocks* of consecutive `makeHandle()`
/// calls. Used by the CLI to rotate the Ollama target model across a campaign
/// when the caller did not pin a specific model with `--model <substr>`.
///
/// ## Why option (b)?
///
/// The #501 brief sketched two designs: an array-of-factories on `FuzzRunner`
/// or a single wrapping factory. The wrapping factory keeps the runner's
/// `init(config:factory:)` contract from #537 intact and isolates rotation
/// behind the existing factory boundary — the runner is unchanged.
///
/// ## Why block rotation?
///
/// `FuzzRunner` calls `makeHandle()` once per iteration, so a step-1
/// round-robin switches the active model on *every* iteration. For a
/// multi-model campaign (`--model all`) that means Ollama/Llama/MLX pay a
/// multi-second model load on nearly every iteration — the resident model is
/// evicted before it does any useful work. Block rotation amortises that cost:
/// the factory stays on the same child for `blockSize` consecutive calls before
/// advancing, so a model loads once and serves a whole block of iterations.
/// With `blockSize == 1` the behaviour is byte-for-byte identical to the
/// original step-1 round-robin, so existing callers are unaffected.
///
/// ## Determinism
///
/// The index is `(callCount / blockSize) % children.count`, where `callCount`
/// is a plain monotonic counter. It reads no wall-clock or random state, so a
/// fixed seed + fixed child order + fixed `blockSize` always yields the same
/// model sequence — the contract `--seed` replay (#490) depends on. The CLI
/// sorts discovered Ollama models by UTF-8 byte order before handing them here,
/// so two invocations on the same machine yield the same sequence regardless of
/// the order Ollama reports them.
///
/// ## Thread safety
///
/// `FuzzBackendFactory` is `Sendable`. The runner is an actor and calls
/// `makeHandle()` serially today, but rotation state is guarded by a
/// `ManagedCriticalState` so a future concurrent caller can't corrupt the
/// index. The struct itself stays a value type; the lock sits behind a
/// reference so `Sendable` conformance holds.
public struct RotatingFuzzFactory: FuzzBackendFactory {

    /// Thread-safe monotonic counter. Reference-typed so the enclosing struct
    /// stays `Sendable` as a value type without copying the counter on clones.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func nextAndAdvance() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value &+= 1
            return current
        }
    }

    public let children: [any FuzzBackendFactory]

    /// Number of consecutive `makeHandle()` calls served by one child before
    /// the rotation advances. `1` restores the original step-1 round-robin.
    public let blockSize: Int

    private let counter: Counter

    /// - Parameters:
    ///   - children: ordered list of child factories to rotate through. Must be
    ///     non-empty. The CLI sorts Ollama model names by UTF-8 byte order
    ///     before wrapping, so the order here is already deterministic.
    ///   - blockSize: how many consecutive `makeHandle()` calls stay on the same
    ///     child before advancing. Must be `>= 1`. Larger blocks keep a model
    ///     resident across more iterations, amortising load cost; the default of
    ///     `1` preserves the historical per-call rotation.
    public init(children: [any FuzzBackendFactory], blockSize: Int = 1) {
        precondition(!children.isEmpty, "RotatingFuzzFactory requires at least one child factory")
        precondition(blockSize >= 1, "RotatingFuzzFactory blockSize must be >= 1")
        self.children = children
        self.blockSize = blockSize
        self.counter = Counter()
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        // Integer-divide the monotonic call count by the block size so each
        // child serves `blockSize` consecutive calls before the index advances.
        let idx = (counter.nextAndAdvance() / blockSize) % children.count
        return try await children[idx].makeHandle()
    }
}
