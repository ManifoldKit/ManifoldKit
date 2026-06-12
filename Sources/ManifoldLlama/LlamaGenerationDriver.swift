#if Llama
import Foundation
import LlamaSwift
import os
import ManifoldInference
import ManifoldHardware

/// Owns the token-generation loop for a single `LlamaBackend.generate()` call.
///
/// `LlamaGenerationDriver` is stateless — every dependency it needs is passed
/// as an explicit parameter to `run()`. This keeps it free of any reference to
/// `LlamaBackend` and makes the generation logic independently testable.
///
/// Conforms to `LocalInferenceAdapter` so cross-backend drift guards (e.g.
/// `LocalBackendRealDriverCoverageTest`) can introspect the composed
/// witnesses without instantiating `LlamaBackend`. Sendable explicitly —
/// the struct has no stored mutable state.
// @_spi(Testing): published only for backend test targets (companion-package split, #1749).
@_spi(Testing) public struct LlamaGenerationDriver: LocalInferenceAdapter {

    public init() {}

    // MARK: - LocalInferenceAdapter conformance

    public let adapterName: String = "llama.generation"
    public let toolCallShape: any LocalToolCallShape = InlineXMLToolCallMarkers()
    public let thinkingMarkerStrategy: LocalThinkingMarkerStrategy = .eagerWhenMarkersPresent
    /// Llama's static capability shape published for drift-guard probing.
    /// Mirrors the payload `LlamaBackend.capabilities` returns once a model
    /// is loaded; conformance to `LocalInferenceAdapter` requires a
    /// driver-level snapshot so coverage tests do not have to boot the
    /// backend.
    public let declaredCapabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [
            .temperature, .topP, .topK, .repeatPenalty,
            .minP, .repetitionPenalty, .presencePenalty, .frequencyPenalty,
        ],
        maxContextTokens: 8192,
        requiresPromptTemplate: true,
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
        supportsThinking: true
    )


    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "inference"
    )

    /// Consecutive identical decoded-token run length that triggers an early exit.
    ///
    /// Small models (e.g. smollm2-135m) can enter visible repetition loops where the same
    /// token string is emitted hundreds of times. The existing `LoopingDetector` catches this
    /// after the fact; this constant lets the generation loop break out as soon as the
    /// repetition is unambiguous, saving KV-cache cycles and wall time.
    private static let maxRepeatWindow = 20

    /// Maximum phrase length (in tokens) to scan for repeated sequences.
    private static let maxPhraseLen = 20
    /// Minimum consecutive phrase repetitions before early exit.
    private static let minPhraseRepeats = 3
    /// Capacity of the phrase-detection token buffer (maxPhraseLen × minPhraseRepeats + 1).
    private static let phraseWindowCap = maxPhraseLen * minPhraseRepeats + 1

    struct DRYSamplerDescriptor: Equatable {
        let nCtxTrain: Int32
        let options: LlamaDRYSamplerOptions

        init?(config: GenerationConfig, nCtxTrain: Int32) {
            guard let options = config.llamaDRY else { return nil }
            self.nCtxTrain = nCtxTrain
            self.options = options
        }
    }

    struct XTCSamplerDescriptor: Equatable {
        let options: LlamaXTCSamplerOptions
        let resolvedSeed: UInt32

        init?(config: GenerationConfig, fallbackSeed: UInt32) {
            guard let options = config.llamaXTC else { return nil }
            self.options = options
            self.resolvedSeed = options.seed ?? fallbackSeed
        }
    }

    struct MirostatV2SamplerDescriptor: Equatable {
        let options: LlamaMirostatV2SamplerOptions
        let resolvedSeed: UInt32

        init?(config: GenerationConfig, fallbackSeed: UInt32) {
            guard let options = config.llamaMirostatV2 else { return nil }
            self.options = options
            self.resolvedSeed = options.seed ?? fallbackSeed
        }
    }

    // MARK: - Run

    /// Executes the generation loop: clears the KV cache, builds the sampler
    /// chain, decodes the prompt in `n_batch`-sized chunks, and runs the
    /// token-generation loop until `maxTokens` visible output tokens are produced,
    /// an EOG token is sampled, or `isCancelled()` returns `true`.
    ///
    /// Thinking tokens (`.thinkingToken` events) do **not** count toward `maxTokens`.
    /// They are governed separately by `config.maxThinkingTokens`. The total loop
    /// iteration count is `maxTokens + effectiveThinkingBudget`, capped to the
    /// remaining KV context space.
    ///
    /// Yields `.token` events into `continuation` and drives `generationStream`
    /// phase transitions (`.streaming`, `.done`, `.failed`). On any error the
    /// continuation is finished with a thrown `InferenceError` and the stream
    /// phase is set to `.failed`.
    ///
    /// - Parameters:
    ///   - context: Live `llama_context *` snapshot captured under `stateLock`.
    ///   - vocab: Live `llama_vocab *` snapshot captured under `stateLock`.
    ///   - tokens: Tokenized prompt (including BOS) — computed before the Task.
    ///   - reuseLen: Number of leading prompt tokens whose KV state was preserved
    ///     from the previous turn by the caller. When > 0, the driver skips
    ///     re-decoding those tokens and emits `.kvCacheReuse(promptTokensReused:)`.
    ///   - maxTokens: Maximum number of new tokens to generate.
    ///   - config: Sampling parameters (temperature, topP, repeatPenalty).
    ///   - markers: Thinking markers for the active template, or nil to disable ThinkingTransform.
    ///     When non-nil, `.thinkingToken` / `.thinkingCompleted` events are emitted for reasoning
    ///     content and `config.maxThinkingTokens` is enforced. When nil, every decoded chunk
    ///     surfaces as a plain `.token` event — there is no longer a sniff-mode fallback that
    ///     retroactively engages the parser on raw `<think>` substrings; auto-detection at
    ///     load time replaced it.
    ///   - isCancelled: Closure that returns `true` when the caller has requested
    ///     cancellation (combines `Task.isCancelled` and the backend's `Atomic<Bool>`).
    ///   - generationStream: Stream whose phase is updated on the main actor.
    ///   - continuation: Raw stream continuation for yielding events.
    /// Returns `true` when the KV cache is in a coherent state after the call
    /// (success or clean cancellation), `false` when a C decode error occurred
    /// and the KV state should be treated as undefined. Callers must clear their
    /// `sessionKVState` when this returns `false`.
    @discardableResult
    func run(
        context: OpaquePointer,
        vocab: OpaquePointer,
        tokens: [llama_token],
        reuseLen: Int,
        maxTokens: Int,
        config: GenerationConfig,
        markers: ThinkingMarkers?,
        isCancelled: () -> Bool,
        generationStream: GenerationStream,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        // Adaptive prefill headroom (issue #1592). Defaults wire the real Mach
        // footprint sampler and free-memory query; tests inject synthetic readings.
        // `prefillFootprintSampler` returns this process's resident bytes; the
        // chunk-to-chunk delta feeds the EWMA. `prefillHeadroomSampler` returns
        // remaining free bytes, sampled fresh each chunk so the guard tracks live
        // pressure. `onPrefillEstimate` reports the learned per-token cost back to
        // the backend so a future load's `ModelLoadPlan` can use a measured budget.
        prefillFootprintSampler: @Sendable () -> UInt64? = { AppMemoryUsage.currentBytes() },
        prefillHeadroomSampler: @Sendable () -> UInt64? = { DeviceCapabilityService.queryAvailableMemory() },
        prefillSafetyFactor: Double = 1.5,
        onPrefillEstimate: (@Sendable (UInt64) -> Void)? = nil
    ) async -> Bool {
        Self.logger.debug("LlamaGenerationDriver run started")

        // MARK: Batch size

        // `n_batch` caps how many tokens can flow through a single
        // `llama_decode` call. llama.cpp asserts
        // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` in
        // `llama-context.cpp`, so prompts longer than this must be decoded
        // in chunks. We never set `n_batch` on `ctxParams`, so it inherits
        // llama.cpp's default (2048 at the time of writing).
        let batchSize = max(1, Int(llama_n_batch(context)))

        // MARK: KV cache clear / reuse

        // When reuseLen > 0 the caller (LlamaBackend.generate) has already trimmed
        // the KV tail beyond the shared prefix via llama_memory_seq_rm — so the
        // reused tokens are already decoded at their correct positions and we must
        // NOT clear them. Only do a full clear when there is nothing to reuse.
        if reuseLen == 0, let memory = llama_get_memory(context) {
            llama_memory_clear(memory, false)
        }

        if reuseLen > 0 {
            continuation.yield(.kvCacheReuse(promptTokensReused: reuseLen))
        }

        // MARK: Sampler chain setup

        // Sampler chain order matters. Grammar (when present) must run BEFORE the
        // probability filters (top_k / top_p / min_p) so it can prune invalid
        // tokens to -inf while every candidate is still in play. If grammar runs
        // after min_p, the filters can shrink the candidate pool to a set that
        // contains no grammar-valid tokens; the grammar then masks all remaining
        // logits to -inf, dist samples a numerical fallback (e.g. token 365 `(`),
        // and the chain's automatic accept step inside `llama_sampler_sample`
        // calls `llama_grammar_accept_token`, which throws
        // `std::runtime_error: Unexpected empty grammar stack` across the C ABI
        // and aborts the process with libc++abi (see prior crash logs from
        // test_grammar_cancelCleansTeardown). Final order:
        //   penalties → grammar → dry → top_k → top_p → min_p → temp → xtc → dist
        // When mirostat v2 is active it replaces the (temp, xtc, dist) tail with
        // a single `mirostat_v2` step that handles both temperature and final
        // selection.

        // Shared sampler parameters, computed once so the permissive (no-grammar)
        // and strict (grammar) chains used by the thinking-phase gate (issue #1595)
        // are byte-identical apart from the grammar stage.

        // Prefer the explicit `repetitionPenalty` knob when callers supplied it; fall
        // back to the legacy `repeatPenalty` field otherwise. The chain is added when
        // ANY of the three penalties is non-no-op; presence and frequency are additive
        // so 0.0 is the no-op value, while repetition is multiplicative so 1.0 is no-op.
        let effectiveRepetitionPenalty = config.repetitionPenalty ?? config.repeatPenalty
        let effectivePresencePenalty = config.presencePenalty ?? 0.0
        let effectiveFrequencyPenalty = config.frequencyPenalty ?? 0.0
        // llama.cpp uses one shared window for all three penalties; default 64 matches
        // pre-existing behaviour. MLX exposes per-penalty windows; llama does not.
        let effectivePenaltyWindow = Int32(config.repetitionContextSize ?? 64)
        let penaltiesActive = effectiveRepetitionPenalty > 1.0
            || effectivePresencePenalty != 0.0
            || effectiveFrequencyPenalty != 0.0

        // Use the caller-supplied seed when available so consecutive runs with the same
        // prompt + config produce identical token streams. `llama_sampler_init_dist`
        // takes `uint32_t`, so we truncate the GenerationConfig's `UInt64` seed —
        // collisions across the truncation boundary are not a correctness issue, only
        // a slight loss of seed-space entropy. Falls back to a fresh random seed when
        // the caller didn't request determinism. Computed once and shared by both
        // chains so the seeded RNG sequence is consistent across a phase switch.
        let samplerSeed: UInt32
        if let seed = config.seed {
            samplerSeed = UInt32(truncatingIfNeeded: seed)
        } else {
            samplerSeed = UInt32.random(in: 0...UInt32.max)
        }

        // Thinking-marker / grammar gating decision (issue #1595).
        //
        // `useParser` mirrors the value recomputed below for the generation loop:
        // a thinking parser runs only when markers are present AND thinking is not
        // explicitly disabled (`maxThinkingTokens == 0`). When a grammar AND a
        // thinking parser are both active we must NOT let the grammar constrain the
        // reasoning block, so we build two chains and gate which one samples each
        // iteration. All other cases (no grammar, or grammar without thinking) keep
        // the single-chain behaviour unchanged.
        let thinkingDisabled = config.maxThinkingTokens == 0
        let useParser = !thinkingDisabled && markers != nil
        let hasGrammar = config.grammar != nil
        let gateGrammarOnThinking = hasGrammar && useParser

        // Outcome of building one sampler chain. `chainInitFailed` and
        // `grammarParseFailed` map to the two distinct error paths the original
        // single-chain code surfaced (different message + different KV-coherence
        // return value), so collapsing them would lose that fidelity.
        enum SamplerBuildOutcome {
            case success(UnsafeMutablePointer<llama_sampler>)
            case chainInitFailed
            case grammarParseFailed
        }

        func makeSampler(includeGrammar: Bool) -> SamplerBuildOutcome {
            let sparams = llama_sampler_chain_default_params()
            guard let sampler = llama_sampler_chain_init(sparams) else {
                return .chainInitFailed
            }
            if penaltiesActive {
                llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                    effectivePenaltyWindow,        // last_n tokens to penalize (shared window)
                    effectiveRepetitionPenalty,    // repeat penalty (multiplicative; 1.0 = no-op)
                    effectiveFrequencyPenalty,     // frequency penalty (additive; 0.0 = no-op)
                    effectivePresencePenalty       // presence penalty (additive; 0.0 = no-op)
                ))
            }

            // Grammar-constrained sampling: GBNF grammar from config, inserted at the
            // front of the chain (right after penalties) so it prunes the logit
            // distribution before any probability-based filter narrows the candidate
            // set. Parse failure (invalid GBNF) is surfaced as an error — silent
            // fallback to unconstrained sampling would produce output that violates
            // the caller's grammar contract.
            if includeGrammar, let grammarString = config.grammar {
                var grammarSamplerCreated = false
                grammarString.withCString { grammarCStr in
                    "root".withCString { rootCStr in
                        if let gs = llama_sampler_init_grammar(vocab, grammarCStr, rootCStr) {
                            llama_sampler_chain_add(sampler, gs)
                            grammarSamplerCreated = true
                        }
                    }
                }
                if !grammarSamplerCreated {
                    llama_sampler_free(sampler)
                    return .grammarParseFailed
                }
            }

            if let model = llama_get_model(context),
               let dry = DRYSamplerDescriptor(config: config, nCtxTrain: llama_model_n_ctx_train(model)) {
                let drySampler = withCStringArray(dry.options.sequenceBreakers) { breakers in
                    var mutableBreakers = breakers
                    return mutableBreakers.withUnsafeMutableBufferPointer { breakerBuffer in
                        llama_sampler_init_dry(
                            vocab,
                            dry.nCtxTrain,
                            dry.options.multiplier,
                            dry.options.base,
                            dry.options.allowedLength,
                            dry.options.penaltyLastN,
                            breakerBuffer.baseAddress,
                            breakerBuffer.count
                        )
                    }
                }
                llama_sampler_chain_add(sampler, drySampler)
            }

            // temperature == 0.0 means true greedy decoding: always pick the argmax token.
            // The stochastic `dist` sampler introduces seed-dependent tie-breaking that can
            // produce non-deterministic output when two logits are numerically equal (a
            // realistic occurrence when the KV cache re-decode path uses a different Metal
            // accumulation order than the original full-batch decode). Using the dedicated
            // greedy sampler eliminates that randomness entirely.
            if config.temperature <= 0.0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            } else {
                // Surface `config.topK` to the sampler chain. Historical default of 40 is
                // preserved when the caller leaves it nil, so existing behaviour is unchanged
                // for callers that never set the field (which previously had no effect).
                let effectiveTopK = config.topK.map { Int32($0) } ?? 40
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(effectiveTopK))
                if config.topP < 1.0 {
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(config.topP, 1))
                }
                // Honour `config.minP` when supplied; default to 0.05 for parity with prior behaviour.
                let effectiveMinP = config.minP ?? 0.05
                llama_sampler_chain_add(sampler, llama_sampler_init_min_p(effectiveMinP, 1))

                // Mirostat v2 owns both the temperature step and the final token selection
                // (it samples internally), so when it is active we skip temp/xtc/dist
                // entirely. When inactive we keep the historical chain tail.
                if let mirostat = MirostatV2SamplerDescriptor(config: config, fallbackSeed: samplerSeed) {
                    llama_sampler_chain_add(sampler, llama_sampler_init_mirostat_v2(
                        mirostat.resolvedSeed,
                        mirostat.options.tau,
                        mirostat.options.eta
                    ))
                } else {
                    llama_sampler_chain_add(sampler, llama_sampler_init_temp(config.temperature))
                    if let xtc = XTCSamplerDescriptor(config: config, fallbackSeed: samplerSeed) {
                        llama_sampler_chain_add(sampler, llama_sampler_init_xtc(
                            xtc.options.probability,
                            xtc.options.threshold,
                            xtc.options.minKeep,
                            xtc.resolvedSeed
                        ))
                    }
                    llama_sampler_chain_add(sampler, llama_sampler_init_dist(samplerSeed))
                }
            }
            return .success(sampler)
        }

        // Strict chain: carries the grammar when the caller supplied one. This is the
        // only chain used for non-thinking models and for thinking-disabled requests,
        // so its construction path is identical to pre-#1595.
        let outputSampler: UnsafeMutablePointer<llama_sampler>
        switch makeSampler(includeGrammar: hasGrammar) {
        case .success(let s):
            outputSampler = s
        case .chainInitFailed:
            await MainActor.run { generationStream.setPhase(.failed("Failed to create sampler")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to create sampler"))
            return false
        case .grammarParseFailed:
            await MainActor.run { generationStream.setPhase(.failed("Failed to parse GBNF grammar")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to parse GBNF grammar string"))
            // KV cache state is untouched at this point — no decode has run yet —
            // so the cache is still coherent and the caller can keep `sessionKVState`.
            return true
        }
        defer { llama_sampler_free(outputSampler) }

        // Permissive chain: identical to the strict chain minus the grammar stage.
        // Built only when gating is required (grammar + thinking both active) and
        // used while the model is inside its reasoning block so the schema cannot
        // clamp `<think>…</think>` tokens. Grammar parse failure cannot occur here
        // (includeGrammar == false). If the chain fails to initialise we fall back
        // to the strict chain — grammar would then (incorrectly) constrain reasoning,
        // but that is strictly better than aborting the generation outright.
        let thinkingSampler: UnsafeMutablePointer<llama_sampler>? = {
            guard gateGrammarOnThinking else { return nil }
            switch makeSampler(includeGrammar: false) {
            case .success(let s):
                return s
            case .chainInitFailed, .grammarParseFailed:
                Self.logger.error("Failed to build thinking-phase sampler; grammar will apply during reasoning")
                return nil
            }
        }()
        defer { if let thinkingSampler { llama_sampler_free(thinkingSampler) } }

        // Phase gate: starts permissive when gating, flips to strict on the first
        // `.thinkingCompleted`. A no-op (always strict) when not gating.
        var grammarGate = GrammarPhaseGate(gateOnThinking: gateGrammarOnThinking)

        // MARK: Chunked prompt decode

        // Process prompt in `n_batch`-sized chunks. A single `llama_decode`
        // call cannot exceed `n_batch` tokens, so we stride through the
        // prompt and decode each chunk separately. Only the last token of
        // the final chunk has `logits = 1` — that's the one we sample from
        // to kick off generation.
        //
        // Start at `reuseLen` to skip the prefix whose KV state was preserved
        // by the caller. When reuseLen == 0 this is equivalent to starting at 0.
        // Adaptive per-model footprint, learned across this prompt's chunks.
        // Stays dormant (guard returns false, estimate nil) until the first
        // accepted sample, so a single-chunk prompt behaves exactly as before.
        var footprintEstimator = PrefillFootprintEstimator()
        var prefillAborted = false

        var promptDecodeFailed = false
        var promptPos = reuseLen
        while promptPos < tokens.count {
            if isCancelled() { break }

            let chunkSize = min(batchSize, tokens.count - promptPos)
            let isLastChunk = (promptPos + chunkSize) == tokens.count

            // Pre-chunk abort guard: if the learned per-token cost predicts this
            // chunk's transient growth (× safety factor) would overrun the free
            // memory remaining right now, decline it and surface
            // `.memoryInsufficient` rather than decoding into a jetsam/Metal kill.
            // No-op until an estimate exists.
            if let remaining = prefillHeadroomSampler(),
               footprintEstimator.wouldExceedHeadroom(
                   remainingBytes: remaining,
                   nextChunkTokens: chunkSize,
                   safetyFactor: prefillSafetyFactor
               ) {
                let required = footprintEstimator.predictedTransientBytes(
                    forTokens: chunkSize,
                    safetyFactor: prefillSafetyFactor
                ) ?? remaining
                Self.logger.error(
                    "Llama prefill aborted: predicted \(required) bytes for next chunk exceeds \(remaining) free"
                )
                prefillAborted = true
                llama_synchronize(context)
                await MainActor.run {
                    generationStream.setPhase(.failed("Insufficient memory for prefill"))
                }
                continuation.finish(
                    throwing: InferenceError.memoryInsufficient(required: required, available: remaining)
                )
                break
            }

            let footprintBefore = prefillFootprintSampler()

            var promptBatch = llama_batch_init(Int32(chunkSize), 0, 1)
            for i in 0..<chunkSize {
                promptBatch.token[i] = tokens[promptPos + i]
                promptBatch.pos[i] = Int32(promptPos + i)
                promptBatch.n_seq_id[i] = 1
                promptBatch.seq_id[i]?[0] = 0
                promptBatch.logits[i] = (isLastChunk && i == chunkSize - 1) ? 1 : 0
            }
            promptBatch.n_tokens = Int32(chunkSize)

            let decodeResult = llama_decode(context, promptBatch)
            llama_batch_free(promptBatch)

            if decodeResult != 0 {
                promptDecodeFailed = true
                break
            }

            // Sample resident footprint after the decode and fold the delta into
            // the EWMA. Negative deltas (allocator/cache reclaim) are rejected by
            // the estimator so they cannot bias the next prediction toward zero.
            let footprintAfter = prefillFootprintSampler()
            footprintEstimator.record(
                beforeBytes: footprintBefore,
                afterBytes: footprintAfter,
                tokensProcessed: chunkSize
            )

            promptPos += chunkSize
        }

        // A pre-chunk abort already finished the continuation with a thrown
        // error; the KV cache holds a partially-decoded prefix, so report it
        // incoherent to force a clean clear on the next turn.
        if prefillAborted {
            return false
        }

        // Surface the learned per-token cost so the backend can retain it and a
        // subsequent load can recompute its `ModelLoadPlan` against a measured
        // budget. Reported only when a real estimate exists.
        if let measured = footprintEstimator.estimatedBytesPerToken {
            onPrefillEstimate?(measured)
        }

        if promptDecodeFailed {
            Self.logger.error("Llama prompt decode failed")
            // Synchronize before returning so any partially-committed Metal
            // command buffers from the prompt chunks that did succeed are
            // flushed.  The next generate() call will clear the KV cache;
            // without this fence that clear can race with in-flight GPU work.
            llama_synchronize(context)
            await MainActor.run { generationStream.setPhase(.failed("Failed to decode prompt")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to decode prompt"))
            return false
        }

        // Honour cancellation that fired mid-prompt before entering the
        // generation loop.
        if isCancelled() {
            // Flush any Metal ops from prompt chunks already decoded.
            llama_synchronize(context)
            await MainActor.run { generationStream.setPhase(.done) }
            continuation.finish()
            return true
        }

        // MARK: Token generation loop

        // Generation loop uses a fresh 1-capacity batch — the prompt loop
        // allocated and freed a batch per chunk, so there's nothing to
        // reuse here.
        var genBatch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(genBatch) }

        // The chunked prompt loop placed tokens at positions
        // [0, tokens.count - 1]; the next decoded token goes at
        // `tokens.count`.
        var nCur = tokens.count
        var invalidUTF8: [CChar] = []
        var isFirstToken = true

        // Thinking-marker handling has two modes:
        //
        // 1. Eager — `markers != nil` (caller passed explicit markers, or the
        //    backend auto-detected them from the GGUF chat template). Every
        //    decoded token flows through `ThinkingTransform` from the first byte.
        //
        // 2. Disabled — `markers == nil`. The model does not advertise reasoning
        //    blocks, so every token yields `.token` with no tag scanning. Raw
        //    `<think>` substrings (if the model emits them anyway) surface as
        //    visible text rather than `.thinkingToken` events. This matches
        //    non-reasoning models' fast path. Removed in this change: an
        //    earlier "sniff" mode that probed the first 64 bytes for `<think>`
        //    and retroactively engaged the parser. Auto-detection at load time
        //    (LlamaModelLoader.readChatTemplateMetadata) replaced it.
        //
        // Special case: `config.maxThinkingTokens == 0` disables thinking entirely
        // (issue #597). Even when `markers` is non-nil, the parser stays off and
        // every decoded token flows straight to `.token`. The model may still
        // emit raw `<think>` / `</think>` substrings, but the driver routes
        // them as visible text rather than `.thinkingToken` events.
        // `thinkingDisabled` / `useParser` were computed once during sampler setup
        // above (the grammar gate needs them before the chains are built); reuse
        // those values here rather than re-deriving them.
        var thinkingTokenCount = 0
        // Flag set when maxThinkingTokens is reached so we can break the outer loop cleanly.
        var thinkingLimitReached = false
        // Visible-output token counter. Thinking tokens do NOT count toward maxTokens —
        // maxOutputTokens governs visible output budget, and maxThinkingTokens governs the
        // reasoning budget separately. Without this split, a reasoning model that thinks for
        // N tokens before answering consumes the entire maxOutputTokens budget in the thinking
        // phase and never emits any visible output (see issue #519 regression: Qwen3-0.6B
        // exhausted a 256-token budget in <think>…</think> and never reached EOG).
        var visibleTokenCount = 0
        // Total loop iterations = visible budget + thinking budget. When thinking is
        // disabled (useParser == false) the thinking budget is 0, so the loop cap equals
        // maxTokens exactly — identical to the previous behaviour for non-thinking models.
        //
        // The thinking budget is capped to the remaining context slots so the driver
        // never runs llama_decode past the context window even when maxThinkingTokens
        // is nil (defaulting to maxTokens). With a small context (e.g. 512 tokens in
        // tests) and a large prompt, the effective budget shrinks accordingly.
        let contextCapacity = Int(llama_n_ctx(context))
        let usedSlots = tokens.count  // prompt occupies this many KV slots already
        let remainingSlots = max(0, contextCapacity - usedSlots)
        let rawThinkingBudget = useParser ? (config.maxThinkingTokens ?? maxTokens) : 0
        let effectiveThinkingBudget = min(rawThinkingBudget, max(0, remainingSlots - maxTokens))
        let totalLoopBudget = maxTokens + effectiveThinkingBudget

        // Tool-call parser: active when the config carries at least one tool definition.
        // Processes `.token` events from the thinking layer (or raw decoded text) and
        // re-routes `<|tool_call>…<|end_of_turn>` / `<tool_call>…</tool_call>` blocks
        // into `.toolCall` events. When no tools are configured the parser is skipped
        // entirely — zero overhead on non-tool-calling generation paths.
        let useToolParser = !config.tools.isEmpty

        // Build the unified output-parsing chain. Order is `[thinking, tool]`:
        // thinking is stripped first, then the tool stage re-scans the remaining
        // visible `.token` text — tool calls never appear inside a thinking
        // block, so the tool stage only ever sees post-thinking text. Preserves
        // Llama's historical two-stage order exactly.
        var stages: [Stage] = []
        if useParser {
            stages.append(.thinking(ThinkingTransform(markers: markers ?? .qwen3)))
        }
        if useToolParser {
            stages.append(.tool(ToolCallTransform(markers: LlamaToolMarkers.markers())))
        }
        var session = OutputParserSession(stages)

        // Repetition-window state: track the last decoded token string and how
        // many times it has appeared consecutively. Exceeding `maxRepeatWindow`
        // triggers an early exit — no need to run the loop all the way to maxTokens.
        var repeatWindowLast = ""
        var repeatWindowCount = 0

        // Phrase-level repetition state: a bounded sliding window (Array, evicted
        // via removeFirst — O(n) but cap=61 so cost is negligible) of the last
        // `phraseWindowCap` decoded token strings. After each token is appended,
        // the tail is scanned for back-to-back phrase repetitions of lengths 2–20.
        var phraseWindow: [String] = []
        phraseWindow.reserveCapacity(Self.phraseWindowCap + 1)

        generationLoop: for iteration in 0..<totalLoopBudget {
            if isCancelled() { break }

            // First iteration samples from the final prompt chunk's logits,
            // which llama.cpp exposes at index -1 ("last available").
            // Subsequent iterations sample from the 1-token gen batch
            // decoded at the end of the previous iteration, at index 0.
            let logitIndex: Int32 = iteration == 0 ? -1 : 0
            // Phase-aware grammar (issue #1595): sample with the permissive chain
            // while the model is reasoning, and with the strict (grammar) chain once
            // `.thinkingCompleted` has flipped the gate. `thinkingSampler` is non-nil
            // only when gating is active and grammar is inactive, so the fallback to
            // `outputSampler` covers every other case (no gating, or already strict).
            let sampler = grammarGate.isGrammarActive ? outputSampler : (thinkingSampler ?? outputSampler)
            let token = llama_sampler_sample(sampler, context, logitIndex)

            if llama_vocab_is_eog(vocab, token) { break }

            // Decode token to text and route through ThinkingTransform when active.
            if let text = LlamaTokenization.tokenToString(token, vocab: vocab, invalidUTF8Buffer: &invalidUTF8) {
                // Single-token repetition guard: identical-token run of ≥maxRepeatWindow
                // terminates the loop. Catches small-model repetition loops (e.g.
                // smollm2-135m emitting " " hundreds of times) before the post-hoc
                // LoopingDetector has to clean them up.
                if text == repeatWindowLast {
                    repeatWindowCount += 1
                    if repeatWindowCount >= Self.maxRepeatWindow {
                        break generationLoop
                    }
                } else {
                    repeatWindowLast = text
                    repeatWindowCount = 1
                }

                // Phrase-level repetition guard: catch multi-token loops (2–20 tokens)
                // that the single-token window misses. Live fuzz runs on smollm2-135m
                // surfaced loops with repeating units such as ASCII-art phrases, HTML
                // timestamp blocks, and RTL override sequences.
                phraseWindow.append(text)
                if phraseWindow.count > Self.phraseWindowCap {
                    phraseWindow.removeFirst()
                }
                let maxScanLen = min(Self.maxPhraseLen, phraseWindow.count / Self.minPhraseRepeats)
                if maxScanLen >= 2 {
                    for phraseLen in 2...maxScanLen {
                        if Self.tailRepeats(phraseWindow, phraseLen: phraseLen, minRepeats: Self.minPhraseRepeats) {
                            break generationLoop
                        }
                    }
                }

                // Route the decoded token through the unified chain. The session
                // runs the thinking transform then the tool transform in order;
                // tool calls never appear inside thinking blocks, so the tool
                // stage only sees post-thinking visible text.
                let events = session.ingest(text)

                // Advance the grammar phase gate: once the reasoning block closes
                // (`.thinkingCompleted`), the strict chain takes over for the next
                // sampled token — the first real output token. No-op when not gating.
                grammarGate.observe(events)

                var visibleBudgetExceeded = false
                for event in events {
                    if isFirstToken {
                        switch event {
                        case .token, .thinkingToken:
                            // Trigger .streaming on first reasoning token too — models can think
                            // for 30s before any visible output; staying in .connecting is poor UX.
                            await MainActor.run { generationStream.setPhase(.streaming) }
                            isFirstToken = false
                        default: break
                        }
                    }
                    continuation.yield(event)
                    switch event {
                    case .thinkingToken:
                        thinkingTokenCount += 1
                        if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                            thinkingLimitReached = true
                        }
                    case .token:
                        visibleTokenCount += 1
                        if visibleTokenCount >= maxTokens {
                            visibleBudgetExceeded = true
                        }
                    default: break
                    }
                    if thinkingLimitReached || visibleBudgetExceeded { break }
                }
                if thinkingLimitReached || visibleBudgetExceeded { break generationLoop }
            }

            // Prepare next batch
            genBatch.n_tokens = 0
            genBatch.token[0] = token
            genBatch.pos[0] = Int32(nCur)
            genBatch.n_seq_id[0] = 1
            genBatch.seq_id[0]?[0] = 0
            genBatch.logits[0] = 1
            genBatch.n_tokens = 1
            nCur += 1

            if isCancelled() { break }

            if llama_decode(context, genBatch) != 0 {
                // Synchronize before surfacing the error so the GPU drains any
                // work that *did* commit before the failure.  Without this, a
                // subsequent KV-cache clear from a retry can race Metal ops.
                llama_synchronize(context)
                await MainActor.run { generationStream.setPhase(.failed("Decode failed during generation")) }
                continuation.finish(throwing: InferenceError.inferenceFailure("Decode failed during generation"))
                return false
            }
        }

        // Flush any bytes held back by the chain's tag-boundary buffers. The
        // session cascades each stage's finalize output through the stages
        // downstream of it (thinking → tool), and is a no-op when the chain is
        // empty (neither thinking nor tool parsing was engaged).
        for event in session.finalize() {
            continuation.yield(event)
        }

        // Flush all pending Metal command buffers before returning.
        //
        // `llama_decode` enqueues Metal compute passes asynchronously — by the
        // time the generation loop exits (EOG, cancellation, or token budget),
        // the GPU may still be executing the last batch.  If the caller
        // immediately starts a new `generate()` call, the KV-cache clear
        // (`llama_memory_clear` / `llama_memory_seq_rm`) at the top of the next
        // run enqueues *new* Metal operations before the previous command buffers
        // have committed.  That ordering violation trips llama.cpp's internal
        // render-set assertion:
        //
        //   GGML_ASSERT([rsets->data count] == 0)   (ggml-metal-device.m:618)
        //
        // which leads to corrupted KV state and, on the very next `llama_decode`,
        // a Swift array bounds crash (ContiguousArrayBuffer.swift:692).
        // `llama_synchronize` blocks the calling thread until the GPU is idle,
        // making the context safe for the next caller.  The call is cheap when
        // the GPU is already done (typically sub-millisecond) and is the
        // authoritative fix recommended by the llama.cpp contract (see
        // `docs/LLAMA_CONTRACT.md` and `llama.h` line 972).
        llama_synchronize(context)

        await MainActor.run { generationStream.setPhase(.done) }
        Self.logger.debug("LlamaGenerationDriver run finished")
        continuation.finish()
        return true
    }

    // MARK: - Phrase Detection

    /// Returns true when the tail of `window` contains `minRepeats` consecutive
    /// identical phrases of length `phraseLen`.
    private static func tailRepeats(_ window: [String], phraseLen: Int, minRepeats: Int) -> Bool {
        let needed = phraseLen * minRepeats
        guard window.count >= needed else { return false }
        let n = window.count
        let phrase = window[(n - phraseLen)...]
        for rep in 1..<minRepeats {
            let start = n - phraseLen * (rep + 1)
            let end   = n - phraseLen * rep
            guard start >= 0 else { return false }
            if window[start..<end].elementsEqual(phrase) == false { return false }
        }
        return true
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>?]) -> Result
    ) -> Result {
        var pointers: [UnsafePointer<CChar>?] = []

        func append(_ index: Int) -> Result {
            guard index < strings.count else {
                return body(pointers)
            }

            return strings[index].withCString { pointer in
                pointers.append(pointer)
                defer { pointers.removeLast() }
                return append(index + 1)
            }
        }

        return append(0)
    }
}
#endif
