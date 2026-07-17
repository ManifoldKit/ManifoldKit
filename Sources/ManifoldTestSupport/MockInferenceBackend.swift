import Foundation
import Darwin
import ManifoldInference

/// Configurable mock inference backend for testing.
///
/// Shared across all test targets via the `ManifoldTestSupport` module.
public final class MockInferenceBackend: InferenceBackend, ConversationHistoryReceiver, StructuredHistoryReceiver, @unchecked Sendable {
    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false

    /// Enqueue-throw hook (#1606 error path).
    ///
    /// `InferenceService.enqueue` never calls into the backend synchronously
    /// — the only backend read on the enqueue path is `capabilities`, whose
    /// tool-calling gate rejects tool-carrying requests up front
    /// (`supportsToolCalling == false` → enqueue throws before any stream or
    /// token exists). When this flag is `true`, the ``capabilities`` getter
    /// reports `supportsToolCalling == false` regardless of the configured
    /// value, so the next tool-carrying enqueue throws synchronously — AFTER
    /// the runtime has advertised and registered session tool executors.
    ///
    /// Use to exercise the register-then-enqueue-fails cleanup path
    /// (``SessionToolDispatchBinder``'s error-path unregister). Requests
    /// without tools are unaffected.
    public var rejectToolCarryingEnqueues: Bool = false

    /// Backing store for ``capabilities``; the getter rewrites
    /// `supportsToolCalling` when ``rejectToolCarryingEnqueues`` is set.
    private var storedCapabilities: BackendCapabilities

    public var capabilities: BackendCapabilities {
        get {
            guard rejectToolCarryingEnqueues else { return storedCapabilities }
            let caps = storedCapabilities
            return BackendCapabilities(
                supportedParameters: caps.supportedParameters,
                maxContextTokens: caps.maxContextTokens,
                requiresPromptTemplate: caps.requiresPromptTemplate,
                supportsSystemPrompt: caps.supportsSystemPrompt,
                supportsToolCalling: false,
                supportsStructuredOutput: caps.supportsStructuredOutput,
                supportsNativeJSONMode: caps.supportsNativeJSONMode,
                cancellationStyle: caps.cancellationStyle,
                supportsTokenCounting: caps.supportsTokenCounting,
                memoryStrategy: caps.memoryStrategy,
                maxOutputTokens: caps.maxOutputTokens,
                supportsStreaming: caps.supportsStreaming,
                isRemote: caps.isRemote,
                supportsKVCachePersistence: caps.supportsKVCachePersistence,
                supportsGrammarConstrainedSampling: caps.supportsGrammarConstrainedSampling,
                supportsThinking: caps.supportsThinking,
                supportsVision: caps.supportsVision,
                streamsToolCallArguments: caps.streamsToolCallArguments,
                supportsParallelToolCalls: caps.supportsParallelToolCalls,
                supportsGuidedStructuredOutput: caps.supportsGuidedStructuredOutput,
                sharesMLXProcessResources: caps.sharesMLXProcessResources,
                maxAdvertisedToolCount: caps.maxAdvertisedToolCount
            )
        }
        set { storedCapabilities = newValue }
    }

    // Configurable behavior
    public var tokensToYield: [String] = ["Hello", " world"]
    public var thinkingTokensToYield: [String] = []

    /// Multi-block reasoning script. When non-empty this **takes precedence
    /// over** ``thinkingTokensToYield``: each inner array is one reasoning
    /// block, emitted as a sequence of `.thinkingToken` events followed by
    /// a `.thinkingCompleted`. Used by tests that exercise the multi-block
    /// finalize path (#604: Anthropic emits one signature per block).
    public var thinkingBlocksToYield: [[String]] = []

    /// Optional signature to emit (via `.thinkingSignature`) immediately
    /// after the thinking tokens of the block at index `i`. `nil` skips
    /// emission for that block. Padded shorter than ``thinkingBlocksToYield``
    /// is fine — missing entries are treated as `nil`.
    public var signaturesPerThinkingBlock: [String?] = []

    /// When `true`, the mock emits `.thinkingToken`/`.thinkingSignature` for
    /// the configured thinking script but withholds the closing
    /// `.thinkingCompleted` event — simulating a backend that never signals
    /// the end of a reasoning block. Lets tests exercise the executor's
    /// end-of-stream "unclosed thinking block" finalize path (the
    /// `accumulator.hasOpenThinkingBlock` branch) deterministically, without
    /// relying on a timing-sensitive mid-stream cancel.
    public var omitThinkingCompletedEvent: Bool = false
    public var shouldThrowOnGenerate: Error? = nil
    public var shouldThrowOnLoad: Error? = nil

    /// Error to throw INSIDE the stream after yielding all tokens.
    /// This simulates network/stream failures that real backends deliver
    /// via the AsyncThrowingStream rather than from generate() itself.
    public var shouldThrowInsideStream: Error?

    /// Tool calls to emit during generation, interleaved after all text tokens.
    ///
    /// When non-empty the backend emits all ``tokensToYield`` tokens first,
    /// then emits one ``GenerationEvent/toolCall(_:)`` event per entry in
    /// this array before finishing the stream.  This lets tests assert on
    /// the full stream event sequence without wiring up a real backend.
    public var scriptedToolCalls: [ToolCall] = []

    /// Per-turn tool calls for tests that exercise the orchestrator's
    /// tool-dispatch loop.
    ///
    /// Each call to ``generate(prompt:systemPrompt:config:)`` pops the first
    /// entry (its elements become `scriptedToolCalls` for that one call).
    /// When this queue is non-empty it takes precedence over the flat
    /// ``scriptedToolCalls`` property; once the queue is drained the backend
    /// emits no further tool calls even if ``scriptedToolCalls`` was seeded.
    /// This mirrors the real-world pattern where a model emits a tool call on
    /// turn N and then finalises visible text on turn N+1.
    public var scriptedToolCallsPerTurn: [[ToolCall]] = []

    /// Tokens the backend will yield on turn N, when
    /// ``scriptedToolCallsPerTurn`` is driving the conversation. Entries are
    /// popped in step with the per-turn tool-call queue. Empty queue falls
    /// back to the flat ``tokensToYield`` property.
    public var tokensToYieldPerTurn: [[String]] = []

    /// A scripted streaming tool-call event the mock can emit before the
    /// authoritative ``GenerationEvent/toolCall(_:)``. Mirrors what cloud
    /// streaming backends produce for backends that flip
    /// ``BackendCapabilities/streamsToolCallArguments``.
    public enum ScriptedToolCallDelta: Sendable {
        /// `.toolCallStart(callId:name:)` event.
        case start(callId: String, name: String)
        /// `.toolCallArgumentsDelta(callId:textDelta:)` event.
        case delta(callId: String, textDelta: String)
        /// Authoritative `.toolCall(_:)` event that closes a streamed call.
        case call(ToolCall)
    }

    /// Scripted streaming tool-call delta sequence per turn. When a turn's
    /// inner array is non-empty, it takes precedence over the per-turn
    /// `(scriptedToolCallsPerTurn, tokensToYieldPerTurn)` for tool-call
    /// emission: events fire in the order listed. Visible-text tokens for
    /// that turn still come from ``tokensToYieldPerTurn`` at the matching
    /// index.
    ///
    /// Use this to drive tests that exercise the streaming-delta path —
    /// e.g. asserting the orchestrator forwards `.toolCallStart` /
    /// `.toolCallArgumentsDelta` verbatim before the closing `.toolCall`.
    public var scriptedToolCallDeltasPerTurn: [[ScriptedToolCallDelta]] = []

    /// When non-nil the mock yields `.kvCacheReuse(promptTokensReused:)` at the
    /// very start of every `generate()` call before any thinking or visible
    /// tokens. Mirrors the real-backend contract — `LlamaGenerationDriver` and
    /// `MLXBackend` both emit this event before the first decode step when a
    /// prefix from the previous turn was preserved. Tests assert on the count
    /// and value to ground-truth tool-loop / multi-turn KV-reuse coverage
    /// without needing a real model. Per-turn scripting via
    /// ``kvCacheReuseToYieldPerTurn`` takes precedence when configured.
    public var kvCacheReuseToYield: Int?

    /// Per-turn KV-reuse counts. Each call to `generate()` pops the first
    /// entry; that value is yielded as `.kvCacheReuse(promptTokensReused:)`.
    /// Falls back to ``kvCacheReuseToYield`` once the queue drains. Use to
    /// assert tool-loop reuse is non-decreasing across rounds.
    public var kvCacheReuseToYieldPerTurn: [Int] = []

    /// Per-turn token-usage counts. Each call to `generate()` pops the first
    /// entry; that `(prompt, completion)` pair is yielded as the terminal
    /// `.usage(TokenUsage(...))` event for that turn (after tokens/tool calls,
    /// before the stream finishes) — matching the real-backend contract where
    /// usage lands at end-of-generation. Empty queue yields no usage event.
    /// Use to drive run-level token-budget tool-loop coverage (#1939 item 3).
    public var usageToYieldPerTurn: [(prompt: Int, completion: Int)] = []

    // Track calls
    public var loadModelCallCount = 0
    public var generateCallCount = 0
    public var stopCallCount = 0
    public var unloadCallCount = 0
    public var resetConversationCallCount = 0

    /// Records whether `loadModel` was called on the main thread.
    /// `nil` until `loadModel` has been called at least once.
    public var loadModelCalledOnMainThread: Bool?

    /// The most recent ``ModelLoadPlan`` passed to `loadModel`. Lets tests assert
    /// on the *requested* context size the load path computed (e.g. that a
    /// per-session `contextSizeOverride` actually shaped the load plan).
    /// `nil` until `loadModel` has been called at least once.
    public var lastLoadPlan: ModelLoadPlan?

    // Capture last generate arguments
    public var lastPrompt: String?
    public var lastSystemPrompt: String?
    public var lastConfig: GenerationConfig?
    /// The per-request ``GenerationRuntimeHints`` from the most recent
    /// `generate(...)` call — split out of ``GenerationConfig`` in #2152.
    public var lastHints: GenerationRuntimeHints?

    /// Stored so stopGeneration() can terminate the in-flight stream.
    ///
    /// Protected by `continuationLock` — written from the generation Task
    /// (on an arbitrary thread) and read/cleared from stopGeneration() which
    /// can be called concurrently from any thread. Without serialization this
    /// is a data race under TSan.
    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private let continuationLock = NSLock()

    /// Optional per-token emission gate. When non-nil, the mock awaits
    /// ``TokenEmissionGate/waitForAdvance()`` BEFORE yielding each visible
    /// token in `tokens`. The test drives token emission deterministically
    /// by calling ``TokenEmissionGate/advance()`` once per token it wants
    /// to release. This eliminates the race in cancel-mid-stream tests
    /// where the unbounded AsyncStream buffer can otherwise contain the
    /// terminal `streamFinished(.stop)` event before the test's cancel
    /// call has propagated.
    public var tokenEmissionGate: TokenEmissionGate?

    /// Optional per-tool-delta emission gate. Same shape as
    /// ``tokenEmissionGate``: when non-nil, the mock awaits
    /// ``TokenEmissionGate/waitForAdvance()`` BEFORE yielding each entry
    /// of ``scriptedToolCallDeltasPerTurn``. Used by cancel-between-deltas
    /// contract tests.
    public var toolDeltaEmissionGate: TokenEmissionGate?

    public init(capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )) {
        self.storedCapabilities = capabilities
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        loadModelCallCount += 1
        loadModelCalledOnMainThread = pthread_main_np() != 0
        lastLoadPlan = plan
        if let error = shouldThrowOnLoad { throw error }
        isModelLoaded = true
    }

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        generateCallCount += 1
        lastPrompt = prompt
        lastSystemPrompt = systemPrompt
        lastConfig = config
        lastHints = hints
        if let error = shouldThrowOnGenerate { throw error }
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }

        // Honor the documented BackendCapabilities contract: a backend that
        // disclaims supportsGrammarConstrainedSampling MUST throw
        // unsupportedGrammar when given a non-nil grammar. The mock matched
        // that contract once tests began asserting it (T1.1 meta-contract).
        if !capabilities.supportsGrammarConstrainedSampling, config.grammar != nil {
            throw InferenceError.unsupportedGrammar(reason: "MockInferenceBackend does not support grammar-constrained sampling")
        }

        isGenerating = true
        // Per-turn scripting takes precedence when configured. Pop from the
        // front so successive generate() calls drive different turns.
        //
        // When this turn has a non-empty delta sequence it takes precedence
        // for tool-call emission, so we must NOT also pop
        // `scriptedToolCallsPerTurn` for this turn — otherwise mixing both
        // queues silently desyncs future turns. Tokens for the turn still
        // come from `tokensToYieldPerTurn` at the matching index.
        let toolCalls: [ToolCall]
        let tokens: [String]
        let deltaSequence: [ScriptedToolCallDelta]
        if !scriptedToolCallDeltasPerTurn.isEmpty {
            deltaSequence = scriptedToolCallDeltasPerTurn.removeFirst()
        } else {
            deltaSequence = []
        }
        if !deltaSequence.isEmpty {
            // Delta sequence drives tool calls this turn; leave the
            // scriptedToolCallsPerTurn queue untouched.
            toolCalls = []
            if !tokensToYieldPerTurn.isEmpty {
                tokens = tokensToYieldPerTurn.removeFirst()
            } else {
                tokens = tokensToYield
            }
        } else if !scriptedToolCallsPerTurn.isEmpty {
            toolCalls = scriptedToolCallsPerTurn.removeFirst()
            if !tokensToYieldPerTurn.isEmpty {
                tokens = tokensToYieldPerTurn.removeFirst()
            } else {
                tokens = tokensToYield
            }
        } else {
            toolCalls = scriptedToolCalls
            if !tokensToYieldPerTurn.isEmpty {
                tokens = tokensToYieldPerTurn.removeFirst()
            } else {
                tokens = tokensToYield
            }
        }

        let thinkingTokens = thinkingTokensToYield

        // Per-turn reuse counts take precedence over the flat property — popped
        // in step with `generate()` so successive calls drive different rounds
        // of a tool loop or multi-turn session.
        let kvReuseCount: Int?
        if !kvCacheReuseToYieldPerTurn.isEmpty {
            kvReuseCount = kvCacheReuseToYieldPerTurn.removeFirst()
        } else {
            kvReuseCount = kvCacheReuseToYield
        }

        // Per-turn usage is popped in step with `generate()` so successive
        // tool-loop iterations report different token counts. `nil` yields no
        // `.usage` event for this turn.
        let usageThisTurn: (prompt: Int, completion: Int)?
        if !usageToYieldPerTurn.isEmpty {
            usageThisTurn = usageToYieldPerTurn.removeFirst()
        } else {
            usageThisTurn = nil
        }

        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            continuationLock.lock()
            self.activeContinuation = continuation
            continuationLock.unlock()
            continuation.onTermination = { @Sendable [self] _ in
                self.continuationLock.lock()
                self.activeContinuation = nil
                self.continuationLock.unlock()
            }
            let multiBlocks = self.thinkingBlocksToYield
            let signatures = self.signaturesPerThinkingBlock
            Task {
                // Real backends emit `.kvCacheReuse` before the first decode
                // step — match that ordering so tests asserting "reuse precedes
                // tokens" hold against both the mock and the real path.
                if let reuseCount = kvReuseCount, !Task.isCancelled {
                    continuation.yield(.kvCacheReuse(promptTokensReused: reuseCount))
                }
                if !multiBlocks.isEmpty {
                    // Multi-block reasoning script: each inner array is one
                    // `<think>…</think>` round, separated by its own
                    // `.thinkingCompleted`. Lets tests assert the per-block
                    // finalize → multi-`.thinking`-part contract.
                    for (idx, block) in multiBlocks.enumerated() {
                        for t in block {
                            if Task.isCancelled { break }
                            continuation.yield(.thinkingToken(t))
                        }
                        if Task.isCancelled { break }
                        if idx < signatures.count, let sig = signatures[idx] {
                            continuation.yield(.thinkingSignature(sig))
                        }
                        if !self.omitThinkingCompletedEvent {
                            continuation.yield(.thinkingCompleted)
                        }
                    }
                } else {
                    for t in thinkingTokens {
                        if Task.isCancelled { break }
                        continuation.yield(.thinkingToken(t))
                    }
                    if !thinkingTokens.isEmpty && !Task.isCancelled && !self.omitThinkingCompletedEvent {
                        continuation.yield(.thinkingCompleted)
                    }
                }
                for token in tokens {
                    if Task.isCancelled { break }
                    if let gate = self.tokenEmissionGate {
                        await gate.waitForAdvance()
                        if Task.isCancelled { break }
                    }
                    continuation.yield(.token(token))
                }
                if !Task.isCancelled {
                    if !deltaSequence.isEmpty {
                        for entry in deltaSequence {
                            if Task.isCancelled { break }
                            if let gate = self.toolDeltaEmissionGate {
                                await gate.waitForAdvance()
                                if Task.isCancelled { break }
                            }
                            switch entry {
                            case .start(let callId, let name):
                                continuation.yield(.toolCallStart(callId: callId, name: name))
                            case .delta(let callId, let textDelta):
                                continuation.yield(.toolCallArgumentsDelta(callId: callId, textDelta: textDelta))
                            case .call(let call):
                                continuation.yield(.toolCall(call))
                            }
                        }
                    } else {
                        for call in toolCalls {
                            if Task.isCancelled { break }
                            continuation.yield(.toolCall(call))
                        }
                    }
                }
                // Terminal usage event lands last (real backends report usage
                // at end-of-generation). Emitted before finish so a consumer
                // draining the stream folds it in for the turn.
                if let usageThisTurn, !Task.isCancelled {
                    continuation.yield(.usage(TokenUsage(
                        promptTokens: usageThisTurn.prompt,
                        completionTokens: usageThisTurn.completion
                    )))
                }
                self.isGenerating = false
                if let streamError = self.shouldThrowInsideStream, !Task.isCancelled {
                    continuation.finish(throwing: streamError)
                    return
                }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() {
        // `stopCallCount` is read-modify-written under the same lock that
        // guards `activeContinuation`. Without synchronization, concurrent
        // stops race on the increment and tests counting fan-out invocations
        // observe lost updates (see StopGenerationConcurrencyTests #418).
        continuationLock.lock()
        stopCallCount += 1
        isGenerating = false
        let cont = activeContinuation
        activeContinuation = nil
        continuationLock.unlock()
        cont?.finish()
    }

    public func unloadModel() {
        unloadCallCount += 1
        isModelLoaded = false
        isGenerating = false
    }

    public func resetConversation() {
        resetConversationCallCount += 1
    }

    // MARK: - ConversationHistoryReceiver

    public var lastReceivedHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        lastReceivedHistory = messages
    }

    /// Last structured history the coordinator handed to this backend.
    /// Tests assert on this to verify the structured threading path
    /// preserves thinking signatures end-to-end (#482, #604).
    public var lastReceivedStructuredHistory: [StructuredMessage]?

    public func setStructuredHistory(_ messages: [StructuredMessage]) {
        lastReceivedStructuredHistory = messages
    }
}

/// Test-only gate that pauses ``MockInferenceBackend`` token emission until
/// the test explicitly releases the next token.
///
/// Used to deflake cancel-mid-stream tests where the unbounded AsyncStream
/// buffer used by `MockInferenceBackend` would otherwise contain the
/// terminal `streamFinished(.stop)` event before the test's cancel call
/// can propagate. By gating token emission, the test can:
///
/// 1. Release token 1.
/// 2. Wait until it observes the corresponding `tokenEmitted` from
///    `runtime.events`.
/// 3. Issue cancel — guaranteed to land BEFORE token 2 enters the buffer.
/// 4. (Optionally release further tokens, which the mock's
///    `Task.isCancelled` check then drops.)
public actor TokenEmissionGate {
    private var pendingPermits: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Suspends the caller until ``advance()`` issues a permit.
    public func waitForAdvance() async {
        if pendingPermits > 0 {
            pendingPermits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// Issues one permit. If a waiter is already suspended, resumes it;
    /// otherwise the permit is buffered for the next ``waitForAdvance()``.
    public func advance() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            pendingPermits += 1
        }
    }

    /// Resumes every pending waiter. Useful in test teardown to ensure
    /// the mock's emission task can finish even when the test no longer
    /// cares about additional tokens.
    public func release() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume() }
    }
}
