#if Llama
import Foundation
import LlamaSwift

/// Process-scoped latch for `llama_backend_init` / `llama_backend_free`.
///
/// llama.cpp documents `llama_backend_init` as exactly-once-per-process — calling
/// the init/free pair more than once is undefined behaviour in GGML / BLAS global
/// init (see `docs/LLAMA_CONTRACT.md` "Global Backend Lifecycle"). Earlier
/// versions of this type refcounted retain/release pairs and called
/// `llama_backend_free()` when the count hit zero, then `llama_backend_init()`
/// again on the next retain. That cycle is the documented UB: in test suites
/// the count routinely dipped to zero between tests, accumulating GGML / Metal
/// global state across re-inits and producing the cross-test flakes tracked
/// in #1319 / #1115.
///
/// The fix is a high-watermark latch: initialise on the first retain and never
/// free for the lifetime of the process. The OS reclaims the GGML globals at
/// `exit()`, which matches llama.cpp's documented expectation. retain/release
/// keep their counter semantics for callers (and tests) that want to observe
/// liveness, but the counter is informational — it no longer drives init/free.
///
/// NSLock is intentional: init/deinit are synchronous, so actor isolation
/// would require fire-and-forget Tasks with no ordering guarantee.
enum LlamaBackendProcessLifecycle {
    nonisolated(unsafe) private static var refCount = 0
    nonisolated(unsafe) private static var didInitialize = false
    private static let lock = NSLock()

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if !didInitialize {
            llama_backend_init()
            didInitialize = true
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        precondition(refCount > 0, "LlamaBackendProcessLifecycle.release() called without a matching retain() — retain/release imbalance")
        refCount -= 1
        // Intentionally NOT calling llama_backend_free() when refCount hits 0.
        // GGML's init/free pair is exactly-once-per-process; the OS reclaims the
        // globals at process exit. See type-doc for #1319.
    }

#if DEBUG
    /// Test-only accessors. Exposed under `DEBUG` so regression tests can pin
    /// the latch invariant without giving production code a mutation surface.
    static var _isInitializedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didInitialize
    }

    static var _refCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return refCount
    }
#endif
}
#endif
