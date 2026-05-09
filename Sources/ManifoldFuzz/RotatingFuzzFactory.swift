import Foundation

/// `FuzzBackendFactory` that round-robins through a fixed list of child factories,
/// advancing one step each time `makeHandle()` is called. Used by the CLI to
/// rotate the Ollama target model per iteration when the caller did not pin a
/// specific model with `--model <substr>`.
///
/// ## Why option (b)?
///
/// The #501 brief sketched two designs: an array-of-factories on `FuzzRunner`
/// or a single wrapping factory. The wrapping factory keeps the runner's
/// `init(config:factory:)` contract from #537 intact and isolates rotation
/// behind the existing factory boundary — the runner is unchanged.
///
/// ## Determinism
///
/// Rotation is a plain monotonic index increment, so replay against a pinned
/// seed is stable as long as the caller provides the same ordered list of
/// child factories. The CLI sorts discovered Ollama models by UTF-8 byte
/// order before handing them here, so two invocations on the same machine
/// yield the same sequence regardless of the order Ollama reports them.
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
    private let counter: Counter

    /// - Parameter children: ordered list of child factories to rotate through.
    ///   Must be non-empty. The CLI sorts Ollama model names by UTF-8 byte
    ///   order before wrapping, so the order here is already deterministic.
    public init(children: [any FuzzBackendFactory]) {
        precondition(!children.isEmpty, "RotatingFuzzFactory requires at least one child factory")
        self.children = children
        self.counter = Counter()
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let idx = counter.nextAndAdvance() % children.count
        return try await children[idx].makeHandle()
    }
}
