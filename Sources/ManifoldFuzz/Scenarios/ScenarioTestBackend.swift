import Foundation
import ManifoldInference

/// Scripted ``InferenceBackend`` used by ``FuzzScenario`` implementations.
///
/// Lives inside `ManifoldFuzz` (rather than `ManifoldTestSupport`) so the
/// library's scenarios stay usable from the CLI and from any host app — the
/// test-support module is only linked by test targets.
///
/// Each scenario drives this backend through a specific emission pattern:
///
/// - `tokensToYield` — the visible tokens emitted after thinking (if any).
/// - `thinkingTokensToYield` — reasoning tokens emitted before visible output.
/// - `emitThinkingComplete` — whether to emit a `.thinkingCompleted` event after
///   the thinking burst. Scenarios covering disable-thinking flip this off.
/// - `pauseBeforeThinkingComplete` — optional sleep *before* emitting
///   `.thinkingCompleted`, giving scenarios a cancellation / retry window that
///   lands mid-thinking rather than after it.
/// - `cancelAfterFirstThinkingToken` — when true, the backend observes
///   `Task.isCancelled` cooperatively and stops the stream once cancellation
///   reaches it, reproducing the real mid-thinking cancel path.
public final class ScenarioTestBackend: InferenceBackend, @unchecked Sendable {
    public var isModelLoaded: Bool = true
    public var isGenerating: Bool = false
    public var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        cancellationStyle: .cooperative
    )

    public var tokensToYield: [String]
    public var thinkingTokensToYield: [String]
    public var emitThinkingComplete: Bool
    public var pauseBeforeThinkingComplete: Duration
    public var streamErrorOnFirstCall: Error?
    public var streamErrorAfterThinking: Error?

    /// Per-turn KV-reuse counts. When non-empty each `generate(…)` pops the
    /// first entry and yields `.kvCacheReuse(promptTokensReused:)` before any
    /// thinking or visible token. Empty queue → no reuse event.
    ///
    /// Mirrors `MockInferenceBackend.kvCacheReuseToYieldPerTurn` so KV-reuse
    /// coverage scenarios can drive deterministic per-round counts without
    /// needing a real backend.
    public var kvCacheReuseToYieldPerTurn: [Int] = []

    /// Incremented each time `generate(…)` is entered. Scenarios use this to
    /// flip behaviour between the first (flaky) call and the retry.
    public private(set) var generateCallCount: Int = 0

    /// Signal raised the first time a `.thinkingToken` leaves the stream.
    /// Scenarios `await` on this to land a cancel exactly mid-thinking instead
    /// of guessing with a sleep.
    public let firstThinkingTokenEmitted = AsyncSignal()

    /// Stored so `stopGeneration()` can terminate the in-flight stream.
    private let continuationLock = NSLock()
    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    public init(
        tokensToYield: [String] = ["Hello", " ", "world", "."],
        thinkingTokensToYield: [String] = [],
        emitThinkingComplete: Bool = true,
        pauseBeforeThinkingComplete: Duration = .milliseconds(0),
        streamErrorOnFirstCall: Error? = nil,
        streamErrorAfterThinking: Error? = nil
    ) {
        self.tokensToYield = tokensToYield
        self.thinkingTokensToYield = thinkingTokensToYield
        self.emitThinkingComplete = emitThinkingComplete
        self.pauseBeforeThinkingComplete = pauseBeforeThinkingComplete
        self.streamErrorOnFirstCall = streamErrorOnFirstCall
        self.streamErrorAfterThinking = streamErrorAfterThinking
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        generateCallCount += 1
        let callIndex = generateCallCount
        let thinking = thinkingTokensToYield
        let visible = tokensToYield
        let emitComplete = emitThinkingComplete
        let pause = pauseBeforeThinkingComplete
        let firstCallError = streamErrorOnFirstCall
        let postThinkError = streamErrorAfterThinking
        // Scenario 1 asserts the CLIENT-level contract that `maxThinkingTokens
        // == 0` produces zero thinking events. The mock honours the explicit
        // zero cap — this mirrors the OllamaBackend parser's drop-on-zero path
        // and lets the scenario run without needing the real HTTP layer.
        let thinkingLimit = config.maxThinkingTokens

        // Pop the per-turn reuse count in step with `generate()`. Done here
        // (outside the stream Task) so successive calls observe the queue's
        // state monotonically rather than racing on it.
        let kvReuseCount: Int? = kvCacheReuseToYieldPerTurn.isEmpty
            ? nil
            : kvCacheReuseToYieldPerTurn.removeFirst()

        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            continuationLock.lock()
            activeContinuation = continuation
            continuationLock.unlock()
            continuation.onTermination = { @Sendable [self] _ in
                continuationLock.lock()
                activeContinuation = nil
                continuationLock.unlock()
            }

            Task { [firstThinkingTokenEmitted] in
                // Real backends emit `.kvCacheReuse` before the first decode
                // step, so do the same here.
                if let reuseCount = kvReuseCount, !Task.isCancelled {
                    continuation.yield(.kvCacheReuse(promptTokensReused: reuseCount))
                }

                // Thinking burst.
                if !thinking.isEmpty {
                    if let limit = thinkingLimit, limit <= 0 {
                        // Honour the explicit-zero cap. No thinking events ever
                        // leave the stream.
                    } else {
                        for (idx, t) in thinking.enumerated() {
                            if Task.isCancelled { break }
                            if let limit = thinkingLimit, idx >= limit { break }
                            continuation.yield(.thinkingToken(t))
                            if idx == 0 { firstThinkingTokenEmitted.signal() }
                        }
                        if pause > .zero {
                            try? await Task.sleep(for: pause)
                        }
                        if !Task.isCancelled && emitComplete {
                            continuation.yield(.thinkingCompleted)
                        }
                    }
                }

                // If the first call should fail mid-stream (scenario 3's retry
                // path), throw after thinking but before any visible output so
                // the retry re-enters this method and emits a fresh, clean
                // thinking + visible pair.
                if callIndex == 1, let err = firstCallError {
                    isGenerating = false
                    continuation.finish(throwing: err)
                    return
                }

                if let err = postThinkError {
                    isGenerating = false
                    continuation.finish(throwing: err)
                    return
                }

                // Visible burst.
                for token in visible {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }

                isGenerating = false
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() {
        isGenerating = false
        continuationLock.lock()
        let cont = activeContinuation
        activeContinuation = nil
        continuationLock.unlock()
        cont?.finish()
    }

    public func unloadModel() {
        isModelLoaded = false
        isGenerating = false
    }
}

/// One-shot async signal. Scenarios `await` on `.wait()` to synchronise
/// cancellation / retry timing against a specific stream event without sleeps.
public final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func signal() {
        lock.lock()
        let pending: [CheckedContinuation<Void, Never>]
        if signalled {
            lock.unlock()
            return
        }
        signalled = true
        pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume() }
    }

    public func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signalled {
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
    }
}
