import Foundation
import Synchronization
import ManifoldInference

/// A test double that deterministically injects streaming failures.
///
/// `MockInferenceBackend` only reveals happy-path bugs. Real backends can
/// drop the socket mid-stream, take a long time to reach the first token,
/// deliver bursts of tokens followed by a stall, or surface a transport error
/// partway through a response. Each of those scenarios produces a distinct
/// UX failure mode in the chat layer: orphaned typing indicators, partial
/// assistant messages, stuck loading states, missing error banners.
///
/// `ChaosBackend` reproduces each scenario on demand so tests can pin the
/// expected behaviour. The failure mode is set via ``mode`` and is honoured
/// on every subsequent call to ``generate(prompt:systemPrompt:config:)``.
///
/// ## Reproducibility
///
/// All timings are scheduled with `Task.sleep(for:)` against real wall-clock
/// time. Tests should keep delays small (≤ 100 ms) to stay CI-friendly. The
/// backend does not use a PRNG — every failure mode is deterministic given
/// the same inputs, which makes assertions straightforward.
public final class ChaosBackend: InferenceBackend, @unchecked Sendable {

    /// Failure modes the backend can inject into its stream.
    public enum FailureMode: Sendable, Equatable {
        /// Yields tokens and finishes normally. Baseline happy-path.
        case none

        /// Yields `afterTokens` tokens, then terminates the stream without
        /// throwing or finishing the remaining tokens. Simulates a socket
        /// drop where the server closes the connection silently.
        case dropMidStream(afterTokens: Int)

        /// Delays the first token by `delay`, then streams the rest normally.
        /// Simulates a cold backend, a queued request, or head-of-line blocking.
        case slowFirstToken(delay: Duration)

        /// Yields `burstSize` tokens back-to-back with no delay, then stalls
        /// for `stallDuration` before finishing the remaining tokens.
        /// Exposes UI batching assumptions and idle-timeout tuning.
        case burstThenStall(burstSize: Int, stallDuration: Duration)

        /// Yields `afterTokens` tokens, then throws an `InferenceError` into
        /// the stream. Simulates a transport error mid-generation.
        case networkError(afterTokens: Int)

        /// Yields `afterTokens` tokens, then goes silent for `silenceFor`
        /// without finishing or erroring. The stream stays open. Exercises
        /// the consumer's idle-timeout policy: idle-timeout wrappers like
        /// `withIdleTimeout` should fire; consumers without a timeout should
        /// hang.
        ///
        /// Use a short `silenceFor` (≤ 200ms) in tests so the stream
        /// continues to a natural finish after the timeout expires.
        case idleTimeout(afterTokens: Int, silenceFor: Duration)

        /// Yields `tokensBefore` text tokens, then a single
        /// ``GenerationEvent/toolCall(_:)`` whose arguments string is
        /// `invalidJSON` (intentionally not parseable JSON). Exercises
        /// downstream parser robustness — a tool dispatcher must reject
        /// the call with a structured error rather than crash.
        case malformedToolCall(tokensBefore: Int, callId: String, toolName: String, invalidJSON: String)

        /// Yields `count` parallel ``GenerationEvent/toolCall(_:)`` events
        /// back-to-back, each with id `<idPrefix><index>` and arguments
        /// `{"index": <N>}`. Exercises parallel-tool-call dispatch — the
        /// consumer must invoke all `count` tools, not just the first.
        case parallelToolCalls(count: Int, idPrefix: String, toolName: String)
    }

    private let stateLock = NSLock()
    private var _isModelLoaded = true
    private var _isGenerating = false
    private let lifecycle = MockBackendLifecycle()
    private var _mode: FailureMode
    private var _tokensToYield: [String]

    /// Monotonic count of `.token` events yielded across the lifetime of this
    /// backend. Useful for behaviour assertions that need to confirm a path
    /// was exercised without depending on the exact token sequence.
    public let tokensEmittedCount = Atomic<UInt64>(0)

    /// Monotonic count of `.toolCall` events yielded across the lifetime of
    /// this backend. Distinguishes "model called the tool" from "model talked
    /// about the tool" in test assertions.
    public let toolCallsEmittedCount = Atomic<UInt64>(0)

    /// Monotonic count of mid-stream errors injected across the lifetime of
    /// this backend. Includes `.networkError`. Idle-timeouts do not count
    /// (they don't surface as errors at this layer).
    public let errorsThrownCount = Atomic<UInt64>(0)

    public var isModelLoaded: Bool { withStateLock { _isModelLoaded } }
    public var isGenerating: Bool { withStateLock { _isGenerating } }

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    /// The currently active failure mode. Changes take effect on the next
    /// call to `generate()`; in-flight streams are unaffected.
    public var mode: FailureMode {
        get { withStateLock { _mode } }
        set { withStateLock { _mode = newValue } }
    }

    public var tokensToYield: [String] {
        get { withStateLock { _tokensToYield } }
        set { withStateLock { _tokensToYield = newValue } }
    }

    /// Creates a chaos backend.
    ///
    /// - Parameters:
    ///   - mode: Initial failure mode. Defaults to `.none` (happy path).
    ///   - tokensToYield: The token sequence the backend will attempt to
    ///     produce. Failure modes truncate or interrupt this sequence.
    public init(
        mode: FailureMode = .none,
        tokensToYield: [String] = ["Hello", " ", "world"]
    ) {
        self._mode = mode
        self._tokensToYield = tokensToYield
    }

    deinit {
        cancelGeneration(markModelUnloaded: false)
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        withStateLock { _isModelLoaded = true }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        let (tokens, mode, loaded) = withStateLock {
            (_tokensToYield, _mode, _isModelLoaded)
        }
        guard loaded else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        withStateLock { _isGenerating = true }

        return lifecycle.makeStream(
            onFinish: { [weak self] in
                self?.withStateLock { self?._isGenerating = false }
            },
            body: { [weak self] continuation in
                await Self.runFailureMode(
                    mode: mode,
                    tokens: tokens,
                    continuation: continuation,
                    counters: self
                )
            }
        )
    }

    public func stopGeneration() {
        cancelGeneration(markModelUnloaded: false)
    }

    public func unloadModel() {
        cancelGeneration(markModelUnloaded: true)
    }

    // MARK: - Failure orchestration

    private static func runFailureMode(
        mode: FailureMode,
        tokens: [String],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        counters: ChaosBackend?
    ) async {
        // The lifecycle helper calls `continuation.finish()` after this body
        // returns, so we never need to finish manually except to deliver an
        // error mid-stream (`networkError`). A failed `Task.isCancelled`
        // check just exits the body — the helper closes the continuation.
        switch mode {
        case .none:
            for token in tokens {
                if Task.isCancelled { return }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }

        case .dropMidStream(let afterTokens):
            for (index, token) in tokens.enumerated() {
                if Task.isCancelled { return }
                if index >= afterTokens { return }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }

        case .slowFirstToken(let delay):
            if Task.isCancelled { return }
            try? await Task.sleep(for: delay)
            for token in tokens {
                if Task.isCancelled { return }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }

        case .burstThenStall(let burstSize, let stallDuration):
            for (index, token) in tokens.enumerated() {
                if Task.isCancelled { return }
                if index == burstSize {
                    try? await Task.sleep(for: stallDuration)
                    if Task.isCancelled { return }
                }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }

        case .networkError(let afterTokens):
            for (index, token) in tokens.enumerated() {
                if Task.isCancelled { return }
                if index >= afterTokens { break }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }
            counters?.errorsThrownCount.wrappingAdd(1, ordering: .relaxed)
            continuation.finish(
                throwing: InferenceError.inferenceFailure("Chaos: injected network error")
            )

        case .idleTimeout(let afterTokens, let silenceFor):
            for (index, token) in tokens.enumerated() {
                if Task.isCancelled { return }
                if index >= afterTokens { break }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }
            // Sleep without yielding or finishing — the consumer's idle-timeout
            // policy is what we exercise here. After the silence elapses the
            // body returns and the lifecycle helper finishes the stream.
            try? await Task.sleep(for: silenceFor)

        case .malformedToolCall(let tokensBefore, let callId, let toolName, let invalidJSON):
            for (index, token) in tokens.enumerated() {
                if Task.isCancelled { return }
                if index >= tokensBefore { break }
                continuation.yield(.token(token))
                counters?.tokensEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }
            if Task.isCancelled { return }
            continuation.yield(.toolCall(ToolCall(
                id: callId,
                toolName: toolName,
                arguments: invalidJSON
            )))
            counters?.toolCallsEmittedCount.wrappingAdd(1, ordering: .relaxed)

        case .parallelToolCalls(let count, let idPrefix, let toolName):
            for index in 0..<count {
                if Task.isCancelled { return }
                continuation.yield(.toolCall(ToolCall(
                    id: "\(idPrefix)\(index)",
                    toolName: toolName,
                    arguments: "{\"index\": \(index)}"
                )))
                counters?.toolCallsEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }
        }
    }

    // MARK: - State plumbing

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func cancelGeneration(markModelUnloaded: Bool) {
        withStateLock {
            if markModelUnloaded { _isModelLoaded = false }
            _isGenerating = false
        }
        lifecycle.cancel()
    }
}
