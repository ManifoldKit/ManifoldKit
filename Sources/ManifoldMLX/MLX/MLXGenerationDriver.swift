#if MLX
import Foundation
@preconcurrency import MLX
import MLXLMCommon
import MLXRandom
import os
import ManifoldInference

/// Owns the token-streaming loop for a single `MLXBackend.generate()` call.
///
/// `MLXGenerationDriver` is stateless — every dependency it needs is passed
/// as an explicit parameter to `run()`. It mirrors `LlamaGenerationDriver`'s
/// shape but runs `@MainActor` because every MLX call (`prepare`, `makeCache`,
/// `generate`, KV-cache snapshot capture) shares the single-threaded GPU
/// scheduler with the rest of the MLX runtime.
@MainActor
struct MLXGenerationDriver: LocalInferenceAdapter {

    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - LocalInferenceAdapter conformance

    /// `nonisolated` so cross-backend drift guards can introspect the
    /// composed witnesses from any actor without hopping onto the main
    /// actor. The values are immutable, so this is race-free by
    /// construction.
    nonisolated let adapterName: String = "mlx.generation"
    nonisolated let toolCallShape: any LocalToolCallShape = InlineXMLToolCallMarkers()
    nonisolated let thinkingMarkerStrategy: LocalThinkingMarkerStrategy = .eagerWhenMarkersPresent
    /// MLX's static capability shape published for drift-guard probing.
    /// Mirrors `MLXBackend.capabilities` once a model is loaded; the
    /// driver-level snapshot uses the conservative 8 k context fallback
    /// (the backend overrides this from the loaded manifest at runtime).
    nonisolated let declaredCapabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [
            .temperature, .topP, .topK, .repeatPenalty,
            .minP, .repetitionPenalty, .presencePenalty, .frequencyPenalty,
        ],
        maxContextTokens: 8192,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        supportsNativeJSONMode: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: true,
        memoryStrategy: .resident,
        maxOutputTokens: 4096,
        supportsStreaming: true,
        isRemote: false,
        supportsThinking: true,
        sharesMLXProcessResources: true
    )

    /// Outcome of a `run(...)` call.
    struct RunResult {
        /// `true` when the loop completed without throwing and was not cancelled —
        /// callers may snapshot the prompt cache for next-turn reuse.
        let completedNormally: Bool
    }

    /// Outcome of a `generate(...)` call.
    ///
    /// Wraps `RunResult` and surfaces the inputs the backend needs to schedule
    /// a post-generation prompt-cache snapshot capture. The backend owns the
    /// snapshot lineage (write-token bookkeeping, install under the state
    /// lock), so the driver returns the *materials* for the capture rather
    /// than performing it.
    struct GenerateResult {
        let run: RunResult
        /// Non-nil only when KV-cache reuse was eligible, the run completed
        /// normally, and a prompt-token array was captured during input
        /// preparation. The backend reads this to decide whether to fire a
        /// `MLXPromptCacheCoordinator.makeSnapshotCaptureTask`.
        let snapshotInputs: MLXPromptCacheCoordinator.SnapshotCaptureInputs?
    }

    /// High-level orchestrator: encodes chat messages, prepares the model
    /// input and KV cache (honouring reuse eligibility), seeds the RNG,
    /// constructs `GenerateParameters`, and drives the token stream via
    /// ``run(...)``.
    ///
    /// This is the entry point the backend calls — `run(...)` stays public
    /// to the file so the inner token-streaming loop remains independently
    /// testable, but the backend never has to reach past `generate(...)`.
    ///
    /// On the happy path the function yields `.kvCacheReuse` (when a prompt
    /// prefix was restored) and the full event stream from the inner loop
    /// into `continuation`. The caller is responsible for `continuation.finish()`
    /// and `generationStream.setPhase(...)` once the function returns or
    /// throws. The driver only yields events and updates the "streaming" phase
    /// on first content (mirrors the previous in-backend behaviour).
    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        loadOptions: BackendLoadOptions,
        container: any MLXModelContainerProtocol,
        conversationHistory: [(role: String, content: String)],
        toolAwareHistory: [ToolAwareHistoryEntry]?,
        structuredHistory: [StructuredMessage]?,
        dialect: MLXToolDialect,
        autoDetectedMarkers: ThinkingMarkers?,
        kvCacheReuseEligible: Bool,
        pendingSnapshotTask: Task<Void, Never>?,
        // Re-reading the snapshot AFTER awaiting `pendingSnapshotTask` is load-bearing:
        // the prior turn's snapshot task writes to backend state, and a value captured
        // before the await is always stale on second turn. See driver lines 169-174.
        currentSnapshot: @MainActor @Sendable () -> MLXPromptCacheCoordinator.Snapshot?,
        generationStream: GenerationStream,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        yieldHook: (@Sendable () async -> Void)?
    ) async throws -> GenerateResult {
        // Seed the MLX global RandomState before constructing GenerateParameters
        // so the sampler's per-instance `RandomState()` (initialised from the
        // default state) produces a deterministic token stream. `nil` skips
        // seeding entirely — the process keeps whatever entropy MLX last picked up.
        if let seed = config.seed {
            MLXRandom.seed(seed)
        }

        // KV cache quantization: nil = library default (FP16). 8 / 4 map to mlx's
        // explicit kvBits levels. Group size 64 and quantizedKVStart 0 match
        // mlx-lm Python conventions and have no exposure on the BCK API yet.
        let kvBits: Int? = {
            switch loadOptions.kvCacheQuantization {
            case .f16: return nil
            case .q8:  return 8
            case .q4:  return 4
            }
        }()

        let generateConfig = GenerateParameters(
            kvBits: kvBits,
            temperature: config.temperature,
            topP: config.topP,
            topK: Int(config.topK ?? 0),
            minP: config.minP ?? 0.0,
            repetitionPenalty: config.repetitionPenalty ?? config.repeatPenalty,
            repetitionContextSize: config.repetitionContextSize ?? 20,
            presencePenalty: config.presencePenalty,
            presenceContextSize: config.presenceContextSize ?? 20,
            frequencyPenalty: config.frequencyPenalty,
            frequencyContextSize: config.frequencyContextSize ?? 20,
            prefillStepSize: loadOptions.prefillBatchSize ?? 512
        )

        let effectiveSystemPrompt: String? = {
            if let toolBlock = MLXChatMessageEncoder.buildQwenToolBlock(config: config, dialect: dialect) {
                return (systemPrompt ?? "") + toolBlock
            }
            return systemPrompt
        }()

        let (chatMessages, messages) = try MLXChatMessageEncoder.buildChatMessages(
            prompt: prompt,
            effectiveSystemPrompt: effectiveSystemPrompt,
            conversationHistory: conversationHistory,
            toolAwareHistory: toolAwareHistory,
            structuredHistory: structuredHistory,
            dialect: dialect
        )

        let resolvedMarkers = resolveThinkingMarkers(
            config: config,
            autoDetected: autoDetectedMarkers
        )

        // Wait for any pending KV snapshot capture from the previous turn to
        // complete before we restore from it — otherwise we'd race
        // `Snapshot` writes against reads. Then re-read the snapshot from
        // backend state: a value captured before the await is stale because
        // the snapshot task writes there.
        if kvCacheReuseEligible, let pendingSnapshotTask {
            await pendingSnapshotTask.value
        }
        let resolvedSnapshot: MLXPromptCacheCoordinator.Snapshot? =
            kvCacheReuseEligible ? currentSnapshot() : nil

        let prepared = try await MLXPromptCacheCoordinator.prepareInputAndCache(
            container: container,
            chatMessages: chatMessages,
            messages: messages,
            generateConfig: generateConfig,
            kvCacheReuseEligible: kvCacheReuseEligible,
            snapshot: resolvedSnapshot
        )
        if prepared.reuseLen > 0 {
            continuation.yield(.kvCacheReuse(promptTokensReused: prepared.reuseLen))
        } else if kvCacheReuseEligible {
            // Surface *why* a reuse-eligible turn fell back to a full prefill —
            // hybrid/recurrent layers that can't slice show up here instead of
            // an invisible performance cliff.
            Self.logger.debug(
                "MLX prompt-cache reuse missed: \(prepared.reuseReason.description, privacy: .public)"
            )
        }

        let result = try await run(
            container: container,
            generationInput: prepared.generationInput,
            cache: prepared.cache,
            generateConfig: generateConfig,
            config: config,
            dialect: dialect,
            markers: resolvedMarkers,
            generationStream: generationStream,
            continuation: continuation,
            yieldHook: yieldHook
        )

        let snapshotInputs: MLXPromptCacheCoordinator.SnapshotCaptureInputs? =
            if kvCacheReuseEligible,
               result.completedNormally,
               let ids = prepared.promptTokenIds
            {
                MLXPromptCacheCoordinator.SnapshotCaptureInputs(
                    cache: prepared.cache,
                    promptTokenIds: ids
                )
            } else {
                nil
            }

        return GenerateResult(run: result, snapshotInputs: snapshotInputs)
    }

    /// Resolves the active thinking-marker pair from the per-request override
    /// (`config.thinkingMarkers`), then the load-time auto-detected markers.
    /// Returns `nil` when `config.maxThinkingTokens == 0` (issue #597) or when
    /// neither source supplied markers — both cases keep `ThinkingTransform` off.
    ///
    /// Lives on the driver because marker resolution is generation-time policy.
    /// `MLXBackend.resolveThinkingMarkers` forwards to this for source-compat
    /// with `MLXBackendHelpersTests`.
    nonisolated static func resolveThinkingMarkers(
        config: GenerationConfig,
        autoDetected: ThinkingMarkers?
    ) -> ThinkingMarkers? {
        if config.maxThinkingTokens == 0 { return nil }
        return config.thinkingMarkers ?? autoDetected
    }

    /// Non-static, `@MainActor` forwarder so call sites already inside the
    /// driver's actor don't need to qualify the type.
    func resolveThinkingMarkers(
        config: GenerationConfig,
        autoDetected: ThinkingMarkers?
    ) -> ThinkingMarkers? {
        Self.resolveThinkingMarkers(config: config, autoDetected: autoDetected)
    }

    /// Drives the MLX stream:
    ///   1. Calls `container.generate(...)` to materialise the underlying token stream.
    ///   2. Routes each chunk through the optional tool-call parser, then the optional
    ///      thinking parser.
    ///   3. Enforces `config.maxOutputTokens` and `config.maxThinkingTokens`.
    ///   4. Issues a cooperative `Task.yield()` (or the test hook) every
    ///      `config.yieldEveryNTokens` chunks to keep the WindowServer GPU queue moving.
    ///   5. Flushes both parsers' tail buffers on exit.
    ///
    /// On any thrown error the caller wraps the call in a do/catch and is
    /// responsible for setting the `generationStream`'s failure phase. This
    /// helper only yields events into `continuation`; it does not call
    /// `continuation.finish()` — the caller owns lifecycle.
    func run(
        container: any MLXModelContainerProtocol,
        generationInput: MLXPreparedInput,
        cache: MLXPromptCache,
        generateConfig: GenerateParameters,
        config: GenerationConfig,
        dialect: MLXToolDialect,
        markers: ThinkingMarkers?,
        generationStream: GenerationStream,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        yieldHook: (@Sendable () async -> Void)?
    ) async throws -> RunResult {
        Self.logger.debug("MLXGenerationDriver run started")

        let outputLimit = config.maxOutputTokens
        var outputTokenCount = 0
        var isFirstToken = true

        // Build the unified output-parsing chain. Order is `[tool, thinking]`:
        // tool tags are stripped first, then the thinking transform re-scans the
        // remaining visible `.token` text — preserving MLX's historical
        // two-stage order exactly.
        let useThinkingParser = markers != nil
        // Tool-call stage activates only when tools are configured AND the model
        // speaks a known dialect.
        let useToolParser = !config.tools.isEmpty && dialect != .unknown
        var stages: [Stage] = []
        if useToolParser {
            stages.append(.tool(ToolCallTransform(markers: MLXToolMarkers.markers())))
        }
        if useThinkingParser {
            stages.append(.thinking(ThinkingTransform(markers: markers ?? .qwen3)))
        }
        var session = OutputParserSession(stages)

        // A thinking model that runs away on a 16 GB Mac can OOM mid-generation;
        // the budget gate breaks out of the stream once the limit is reached.
        var thinkingTokenCount = 0
        var thinkingLimitReached = false

        // Wrap `container.generate` in MLX's error handler so that fatal model
        // errors (e.g. Gemma4 MoE broadcast shape mismatch — issue #802) are
        // converted from uncatchable `fatalError` calls into thrown Swift errors
        // that the caller can surface as InferenceError rather than crashing the app.
        //
        // The handler is @Sendable because MLX may invoke it from a C++ thread.
        // MLXErrorCapture is @unchecked Sendable so it can safely cross the
        // boundary. The body is @Sendable because all captured params (container,
        // generationInput, cache, generateConfig) conform to Sendable; generate()
        // handles its own actor isolation internally via ModelContainer.perform.
        final class MLXErrorCapture: @unchecked Sendable {
            var message: String?
        }
        let capture = MLXErrorCapture()
        let mlxStream = try await withErrorHandler(
            { @Sendable in capture.message = capture.message ?? $0 }
        ) { @Sendable in
            try await container.generate(
                input: generationInput,
                cache: cache,
                parameters: generateConfig
            )
        }
        if let message = capture.message {
            throw InferenceError.inferenceFailure(message)
        }

        let yieldEvery = config.yieldEveryNTokens
        var completionTokenCount = 0
        outer: for await generation in mlxStream {
            if Task.isCancelled { break }
            guard let text = generation.chunk else { continue }

            for finalEvent in session.ingest(text) {
                if isFirstToken {
                    switch finalEvent {
                    case .token, .thinkingToken, .toolCall:
                        generationStream.setPhase(.streaming)
                        isFirstToken = false
                    default: break
                    }
                }
                if case .token = finalEvent { outputTokenCount += 1 }
                continuation.yield(finalEvent)
                if case .thinkingToken = finalEvent {
                    thinkingTokenCount += 1
                    if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                        thinkingLimitReached = true
                        break
                    }
                }
            }
            if thinkingLimitReached { break outer }
            if let limit = outputLimit, outputTokenCount >= limit { break }

            // Per-chunk yield: counted on every MLX-emitted chunk regardless
            // of whether it surfaced as visible text, was swallowed by the
            // tool-call parser, or wrapped in thinking tags — so the cadence
            // tracks real generation work.
            completionTokenCount += 1
            if yieldEvery > 0 && completionTokenCount % yieldEvery == 0 {
                if let yieldHook {
                    await yieldHook()
                } else {
                    await Task.yield()
                }
            }
        }

        // Flush the chain's tail buffers. The session cascades each stage's
        // finalize output through the stages downstream of it, so any text the
        // tool stage releases is still scanned by the thinking stage — matching
        // the previous two-stage finalize pipeline.
        for event in session.finalize() {
            continuation.yield(event)
        }

        Self.logger.debug("MLXGenerationDriver run finished")
        return RunResult(completedNormally: !Task.isCancelled)
    }
}
#endif
