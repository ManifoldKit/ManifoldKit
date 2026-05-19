#if Llama
import Foundation

/// Hardware-selection policy shared by the generation-load and embedding-load
/// paths in `ManifoldLlama`. Both paths previously inlined the same logic for
/// `n_gpu_layers` and `n_threads` / `n_threads_batch`; the duplication had
/// drifted (the embedding path did not honor `LLAMA_FORCE_CPU_ONLY=1`).
///
/// Functions take their inputs (environment, processor count) as parameters
/// so callers can unit-test the policy without mutating process state.
internal enum LlamaSamplingPolicy {

    /// Returns the `n_gpu_layers` value to use for a llama.cpp model load.
    ///
    /// - Simulator builds always return `0` — Metal is not reliable in the
    ///   iOS Simulator and `MLXBackend`/`LlamaBackend` tests skip there.
    /// - On device, `LLAMA_FORCE_CPU_ONLY=1` forces CPU-only execution. This
    ///   is the escape hatch for memory-constrained loads of very large MoE
    ///   models whose Metal command-buffer cannot allocate enough partial
    ///   weights; CPU (mmap-paged) execution is ~8× slower but completes.
    /// - Otherwise we offload all layers (`99`) to Metal.
    ///
    /// See `docs/LLAMA_CONTRACT.md` for the contract around the env var.
    static func gpuLayerCount(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        #if targetEnvironment(simulator)
        return 0
        #else
        if environment["LLAMA_FORCE_CPU_ONLY"] == "1" {
            return 0
        }
        return 99
        #endif
    }

    /// Returns the `n_threads` (and `n_threads_batch`) value bounded into
    /// `[1, 8]`. We reserve two cores for the OS / app so the inference loop
    /// does not starve UI updates; the upper clamp avoids diminishing returns
    /// past 8 hardware threads observed in profiling.
    static func threadCount(
        processorCount: Int = ProcessInfo.processInfo.processorCount
    ) -> Int32 {
        Int32(max(1, min(8, processorCount - 2)))
    }
}
#endif
