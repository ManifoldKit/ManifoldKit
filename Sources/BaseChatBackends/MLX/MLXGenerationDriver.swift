#if MLX
import Foundation
@preconcurrency import MLX
import MLXLMCommon
import os
import BaseChatInference

/// Owns the token-streaming loop for a single `MLXBackend.generate()` call.
///
/// `MLXGenerationDriver` is stateless — every dependency it needs is passed
/// as an explicit parameter to `run()`. It mirrors `LlamaGenerationDriver`'s
/// shape but runs `@MainActor` because every MLX call (`prepare`, `makeCache`,
/// `generate`, KV-cache snapshot capture) shares the single-threaded GPU
/// scheduler with the rest of the MLX runtime.
@MainActor
struct MLXGenerationDriver {

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    /// Outcome of a `run(...)` call.
    struct RunResult {
        /// `true` when the loop completed without throwing and was not cancelled —
        /// callers may snapshot the prompt cache for next-turn reuse.
        let completedNormally: Bool
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

        let useThinkingParser = markers != nil
        // ThinkingParser must always be initialized (its initializer can't take nil).
        // When useThinkingParser is false the parser is never invoked, so the
        // placeholder marker pair is never observed.
        var thinkingParser = ThinkingParser(markers: markers ?? .qwen3)

        // Tool-call parser activates only when tools are configured AND the model
        // speaks a known dialect. It's a no-op pass-through otherwise.
        let useToolParser = !config.tools.isEmpty && dialect != .unknown
        var toolParser = MLXToolCallParser()

        // A thinking model that runs away on a 16 GB Mac can OOM mid-generation;
        // the budget gate breaks out of the stream once the limit is reached.
        var thinkingTokenCount = 0
        var thinkingLimitReached = false

        // Wrap `container.generate` in MLX's error handler so that fatal model
        // errors (e.g. Gemma4 MoE broadcast shape mismatch — issue #802) are
        // converted from uncatchable `fatalError` calls into thrown Swift errors
        // that the caller can surface as InferenceError rather than crashing the app.
        //
        // MLXError.ErrorCapture is @unchecked Sendable so the @Sendable handler
        // can write into it; we read back on the same actor after generate() returns.
        final class MLXErrorCapture: @unchecked Sendable {
            var message: String?
        }
        let capture = MLXErrorCapture()
        let mlxStream = try await withErrorHandler(
            { capture.message = capture.message ?? $0 }
        ) { @MainActor in
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

            let stageOneEvents: [GenerationEvent] = useToolParser
                ? toolParser.process(text)
                : [.token(text)]

            for event in stageOneEvents {
                let finalEvents: [GenerationEvent]
                if case .token(let tokenText) = event, useThinkingParser {
                    finalEvents = thinkingParser.process(tokenText)
                } else {
                    finalEvents = [event]
                }

                for finalEvent in finalEvents {
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

        // Flush both parsers' tail buffers. Tool-parser output flows through
        // the thinking parser to preserve the streaming-loop's two-stage pipeline.
        if useToolParser {
            for event in toolParser.finalize() {
                if case .token(let tokenText) = event, useThinkingParser {
                    for finalEvent in thinkingParser.process(tokenText) {
                        continuation.yield(finalEvent)
                    }
                } else {
                    continuation.yield(event)
                }
            }
        }
        for event in thinkingParser.finalize() {
            continuation.yield(event)
        }

        Self.logger.debug("MLXGenerationDriver run finished")
        return RunResult(completedNormally: !Task.isCancelled)
    }
}
#endif
