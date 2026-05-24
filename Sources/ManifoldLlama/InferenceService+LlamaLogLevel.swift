#if Llama
import ManifoldInference

// MARK: - InferenceService + LlamaLogLevel

extension InferenceService {
    /// Controls how much llama.cpp / ggml-metal output reaches stderr for the
    /// current process.
    ///
    /// Setting this to ``LlamaLogLevel/silent`` suppresses the ~2,000 lines of
    /// `ggml-metal` / llama.cpp initialisation noise that interleave with a
    /// CLI or agentic consumer's stdout, making REPL-style output look broken.
    ///
    /// The default is ``LlamaLogLevel/info``, which preserves the existing
    /// behaviour (all llama.cpp output reaches stderr unchanged).
    ///
    /// Changes take effect immediately — `llama_log_set` is a process-global
    /// hook. Set this property **before** calling ``loadModel(from:plan:)`` to
    /// silence the initialisation output:
    ///
    /// ```swift
    /// let inference = InferenceService()
    /// DefaultBackends.register(with: inference)
    /// inference.llamaLogLevel = .silent  // no ggml-metal noise on stderr
    /// try await inference.loadModel(from: model, plan: plan)
    /// ```
    @MainActor
    public var llamaLogLevel: LlamaLogLevel {
        get { LlamaBackendProcessLifecycle.currentLogLevel }
        set { LlamaBackendProcessLifecycle.setLogLevel(newValue) }
    }
}
#endif
