import Foundation

/// Produces `FuzzRunner.BackendHandle` values for the fuzz runner.
///
/// Factories are plain `Sendable` structs, which keeps them trivially unit-testable
/// and lets multi-backend drivers (`#501 --model all`) iterate an array of them.
/// The runner calls `makeHandle()` when it needs a backend — today once at the
/// start of `run`, but future rotation/multi-turn modes may call it repeatedly.
public protocol FuzzBackendFactory: Sendable {
    /// Construct a fresh `BackendHandle`. Called once per fuzz iteration when
    /// the runner needs a backend (e.g., rotation in #501, or first use today).
    func makeHandle() async throws -> FuzzRunner.BackendHandle

    /// Whether this backend can bit-reproduce an output given the same prompt +
    /// sampler config. Local backends (MLX, Llama with seed+temperature=0,
    /// Foundation) return `true`; cloud backends (Claude, OpenAI) return `false`.
    /// Ollama's seed plumbing varies by model/version — the default is `true`
    /// with an explicit "verify first" note in FUZZING.md.
    ///
    /// `Replayer` short-circuits with `.nonDeterministicBackend` when this is
    /// `false` rather than run a guaranteed-noisy replay and mislead the
    /// developer into thinking the finding is flaky.
    var supportsDeterministicReplay: Bool { get }

    /// Called by `FuzzChatCLI` after the campaign (or replay/shrink) finishes,
    /// before the process exits. Factories that hold resources requiring ordered
    /// shutdown (e.g. `LlamaBackend.unloadAndWait()`) implement this; the default
    /// is a no-op so existing factories need no changes.
    func teardown() async
}

public extension FuzzBackendFactory {
    /// Default: assume deterministic. Cloud factories opt out explicitly.
    var supportsDeterministicReplay: Bool { true }

    /// Default: no teardown needed.
    func teardown() async {}
}
