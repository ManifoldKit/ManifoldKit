#if Llama
import Foundation
import LlamaSwift
import os

// MARK: - LlamaLogLevel

/// Controls how much llama.cpp / ggml-metal log output reaches stderr.
///
/// CLI and agentic consumers routinely see ~2,000 lines of `ggml-metal` /
/// llama.cpp initialisation noise interleaved with their own stdout. Setting
/// ``LlamaLogLevel/silent`` suppresses all of it; ``LlamaLogLevel/warning``
/// keeps only WARN/ERROR lines that signal real problems.
///
/// Set the level before loading any model via ``InferenceService/llamaLogLevel``
/// or by calling ``LlamaBackendProcessLifecycle/setLogLevel(_:)`` directly.
/// Changes take effect immediately because `llama_log_set` is a process-global
/// hook.
///
/// The default is ``LlamaLogLevel/info``, which preserves the behaviour
/// that existed before this API was added (all llama.cpp output reaches stderr
/// unchanged).
public enum LlamaLogLevel: Sendable {
    /// Suppress all llama.cpp / ggml output. Nothing reaches stderr.
    case silent
    /// Only WARN and ERROR messages reach stderr.
    case warning
    /// INFO, WARN, and ERROR messages reach stderr. **Default.**
    case info
    /// All messages including DEBUG reach stderr.
    case verbose
}

// MARK: - C callback (top-level free function required for @convention(c))

/// Passed to `llama_log_set` for ``LlamaLogLevel/warning``. Forwards only
/// GGML_LOG_LEVEL_WARN (3) and GGML_LOG_LEVEL_ERROR (4) to `os_log`.
/// Must be a free function — C function pointers cannot capture Swift closures.
private func _llamaWarnOnlyCallback(
    _ level: ggml_log_level,
    _ text: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let text else { return }
    // GGML_LOG_LEVEL_WARN = 3, GGML_LOG_LEVEL_ERROR = 4
    guard level.rawValue >= 3 else { return }
    let msg = String(cString: text).trimmingCharacters(in: .newlines)
    guard !msg.isEmpty else { return }
    os_log(.error, log: .default, "llama.cpp: %{public}@", msg)
}

// MARK: - LlamaBackendProcessLifecycle

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
    /// Current process-global log level. Guarded by `lock`.
    nonisolated(unsafe) private static var _currentLogLevel: LlamaLogLevel = .info
    private static let lock = NSLock()

    /// Thread-safe read of the current log level.
    static var currentLogLevel: LlamaLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return _currentLogLevel
    }

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if !didInitialize {
            llama_backend_init()
            applyLogLevel(_currentLogLevel)
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

    /// Redirect or suppress llama.cpp / ggml-metal log output for the process.
    ///
    /// Can be called before or after ``retain()`` — the hook is a process-global
    /// and takes effect immediately. Set this before the first ``retain()`` call
    /// (i.e. before ``InferenceService/loadModel(from:plan:)``) to also suppress
    /// the initialisation log burst.
    static func setLogLevel(_ level: LlamaLogLevel) {
        lock.lock()
        defer { lock.unlock() }
        _currentLogLevel = level
        applyLogLevel(level)
    }

    /// Applies a log level to the process-global `llama_log_set` hook.
    /// Must be called with `lock` held.
    private static func applyLogLevel(_ level: LlamaLogLevel) {
        switch level {
        case .silent:
            // nil callback = suppress all llama.cpp / ggml stderr output.
            llama_log_set(nil, nil)
        case .warning:
            // Forward only WARN / ERROR lines. C function pointer required —
            // cannot use a closure with captures here.
            llama_log_set(_llamaWarnOnlyCallback, nil)
        case .info, .verbose:
            // Restore llama.cpp's built-in default. A nil callback tells
            // llama.cpp to use its internal stderr handler — identical to the
            // behaviour before this API was introduced.
            llama_log_set(nil, nil)
        }
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

    static var _currentLogLevelForTesting: LlamaLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return _currentLogLevel
    }
#endif
}
#endif
