#if Llama
import Foundation
import LlamaSwift

/// Refcounts `llama_backend_init` / `llama_backend_free` at process scope.
///
/// `llama_backend_init` is global and must only be called once per process,
/// not per `LlamaBackend` instance. This namespace owns that refcount so
/// `LlamaBackend.init` / `.deinit` can delegate without exposing static
/// mutable state on the backend class.
///
/// NSLock is intentional: init/deinit are synchronous, so actor isolation
/// would require fire-and-forget Tasks with no ordering guarantee.
enum LlamaBackendProcessLifecycle {
    nonisolated(unsafe) private static var refCount = 0
    private static let lock = NSLock()

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if refCount == 0 {
            llama_backend_init()
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        precondition(refCount > 0, "LlamaBackendProcessLifecycle.release() called without a matching retain() — retain/release imbalance")
        refCount -= 1
        if refCount == 0 {
            llama_backend_free()
        }
    }
}
#endif
