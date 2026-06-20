import Foundation

/// Lifecycle state of a single ``ModelExecutor``.
///
/// An executor owns exactly one model's backend and serializes that model's
/// generation. `ExecutorState` is the per-model lifecycle vocabulary the
/// ``ModelExecutorPool`` reasons about when admitting, hot-swapping, and
/// recovering executors. It is deliberately small and value-typed so the
/// `@MainActor` pool can snapshot it for observation without reaching into
/// the executor actor's mutable internals.
///
/// State machine (happy path):
///
///     .loading → .ready ⇄ .generating → .unloaded
///
/// Wedge path:
///
///     .generating → .wedged → (recover) → .loading → .ready
public enum ExecutorState: Sendable, Equatable {
    /// The backend's model is being loaded into memory; not yet usable.
    case loading

    /// The model is loaded and idle — ready to accept a generation.
    case ready

    /// A generation is actively in flight on this executor.
    case generating

    /// A generation exceeded its wedge budget without producing any event
    /// (no token, no completion, no error). The executor is logically stuck
    /// and must be ``ModelExecutor/recover()``-ed before it can serve again.
    ///
    /// NOTE: this is *logical* (timeout/thrown) isolation, not memory-fault
    /// isolation. A segfault or Metal hang in the underlying C/Metal runtime
    /// still takes the whole process down — true crash isolation requires an
    /// out-of-process (XPC) backend and is an explicit non-goal here.
    case wedged

    /// The model has been unloaded and its backend torn down. A terminal
    /// state for this executor instance; the pool drops it from the registry.
    case unloaded

    /// Whether a generation can be dispatched against this executor right now.
    public var canGenerate: Bool {
        self == .ready
    }

    /// Whether this executor is occupying model memory (loaded, generating, or
    /// wedged but not yet torn down). The pool's residency accounting counts
    /// these toward the live-executor budget.
    public var isResident: Bool {
        switch self {
        case .loading, .ready, .generating, .wedged:
            return true
        case .unloaded:
            return false
        }
    }
}
