#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os
import BaseChatInference

/// Apple FoundationModels inference backend for on-device Apple Intelligence models.
///
/// Uses Apple's built-in language model via the FoundationModels framework.
/// Unlike other backends, this does not load external model files — the model
/// is provided by the system. The `loadModel(from:plan:)` URL parameter
/// is ignored; it simply creates a new session and verifies availability.
///
/// Requires iOS 26+ / macOS 26+.
///
/// ## Thinking / reasoning support
///
/// BaseChatKit surfaces reasoning tokens from capable models via
/// ``GenerationEvent/thinkingToken(_:)`` and ``GenerationEvent/thinkingComplete``.
/// The Ollama and Llama backends emit these events today. **FoundationBackend
/// does not**, because Apple's public FoundationModels SDK (Xcode 26.4,
/// module version 1.4.34) exposes no reasoning/thinking surface at all:
///
/// - `LanguageModelSession.ResponseStream<String>.Snapshot` carries only
///   `content: String.PartiallyGenerated` and `rawContent: GeneratedContent`.
///   There is no reasoning field, no `thinking` channel, no parallel stream.
/// - `LanguageModelSession.Response<Content>` exposes only `content`,
///   `rawContent`, and `transcriptEntries` — no reasoning block.
/// - `Transcript.Entry` is `instructions | prompt | toolCalls | toolOutput | response`.
///   There is no `reasoning` / `thinking` / `chainOfThought` case.
/// - `Transcript.Segment` is `text | structure` only.
/// - `GenerationOptions` exposes only `sampling`, `temperature`,
///   `maximumResponseTokens`. There is no `reasoningEffort`,
///   `enableReasoning`, or reasoning-budget knob.
/// - `SystemLanguageModel.UseCase` offers only `.general` and `.contentTagging`.
/// - A case-insensitive search of the entire `FoundationModels.swiftinterface`
///   for `reason|think|chainofthought|cot|scratchpad|deliberat|inner|monolog`
///   returns zero hits outside `Availability.UnavailableReason` and
///   `GenerationError.failureReason` (both unrelated to model reasoning).
///
/// In other words: whatever chain-of-thought Apple's on-device model performs
/// happens opaquely inside the generator. The SDK returns only the final
/// user-visible answer. There is nothing for this backend to map onto
/// `.thinkingToken` or `.thinkingComplete`, and synthesising fake thinking
/// events from the visible content would be misleading.
///
/// When Apple ships a reasoning surface (e.g. a `reasoning` case on
/// `Transcript.Segment`, a `reasoningContent` field on `ResponseStream.Snapshot`,
/// or a reasoning-enabled `UseCase`), this backend should be updated to emit
/// `.thinkingToken` while reasoning is in flight and `.thinkingComplete`
/// exactly once at the transition to visible content, matching the pattern
/// already used by ``OllamaBackend``.
///
/// ## Multimodal / vision support
///
/// BaseChatKit surfaces image attachments via ``MessagePart/image(data:mimeType:)``
/// and gates UI affordances on ``BackendCapabilities/supportsVision``. The
/// MLX, Claude, and OpenAI backends accept image input today; **FoundationBackend
/// does not**, because Apple's public FoundationModels SDK (Xcode 26.4,
/// module version 1.4.34) exposes no image-input surface:
///
/// - `Transcript.Segment` is `text(TextSegment) | structure(StructuredSegment)`.
///   There is no `image` / `attachment` / `media` case, and `TextSegment` /
///   `StructuredSegment` carry only `String` and `GeneratedContent` payloads.
/// - `Transcript.Entry` (instructions, prompt, toolCalls, toolOutput, response)
///   has no image-bearing case.
/// - `Transcript.Prompt` carries only `[Transcript.Segment]`.
/// - `LanguageModelSession.respond(to:)` and `streamResponse(to:)` accept only
///   `String`, `Prompt`, or `@PromptBuilder` closures whose components conform
///   to `PromptRepresentable` — a protocol whose sole requirement is a
///   `Prompt`-typed `promptRepresentation` (text-only, transitively).
/// - A case-insensitive search of the entire `FoundationModels.swiftinterface`
///   for `image|vision|multimodal|cgimage|uiimage|nsimage|cvpixelbuffer|jpeg|png`
///   returns zero hits outside `LanguageModelFeedback.logFeedbackAttachment`,
///   which is a telemetry helper unrelated to model input.
///
/// In other words: the SDK has no Data/CGImage/PixelBuffer ingress for the
/// model. The on-device model itself may be multimodal-capable internally, but
/// host apps cannot pass images through the public API. The backend therefore
/// advertises ``BackendCapabilities/supportsVision`` as `false`; the runtime's
/// pre-flight in ``GenerationQueue`` rejects image-bearing turns with a clear
/// local error before any request is built. Tracked by issue #20.
///
/// When Apple ships an image-input surface (e.g. an `image` case on
/// `Transcript.Segment`, a `Data`-accepting `Prompt` initialiser, or a
/// `PromptRepresentable` extension on `CGImage` / `UIImage`), this backend
/// should be updated to flip the capability flag and translate
/// ``MessagePart/image(data:mimeType:)`` parts into the new SDK type, matching
/// the pattern already used by ``ClaudeBackend`` and ``OpenAIBackend``.
@available(iOS 26, macOS 26, *)
public final class FoundationBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - State

    public var isModelLoaded: Bool {
        withStateLock { _isModelLoaded }
    }

    public var isGenerating: Bool {
        withStateLock { _isGenerating }
    }

    // MARK: - Capabilities

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        // Tool calling is synthesized on top of GuidedGeneration: when
        // `config.tools` is non-empty we ask the SDK to constrain the output to
        // a sum-type schema (`text` or `tool_call`) and emit `.toolCall(...)`
        // when the model picks the tool branch. The orchestrator drives the
        // round trip exactly as it does for cloud and MLX backends.
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        supportsNativeJSONMode: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .external,
        maxOutputTokens: 4096,
        supportsStreaming: true,
        isRemote: false,
        // Apple's FoundationModels SDK (Xcode 26.4) exposes no image-input
        // surface — `Transcript.Segment` is text/structure only, `Prompt`
        // carries only segments, and there is no `Data`/`CGImage` ingress
        // anywhere in the public API. See the type-level doc comment above
        // for the full audit. Flip to `true` and wire MessagePart.image
        // through the SDK when Apple ships an image-bearing segment.
        supportsVision: false,
        // Whole-call emission only — Apple's GuidedGeneration streams the
        // partially-decoded structure but we do not surface name/argument
        // deltas as separate events (parity with MLXBackend's inline parser).
        streamsToolCallArguments: false,
        supportsGuidedStructuredOutput: true
    )

    // MARK: - Private

    private let stateLock = NSLock()
    private var _isModelLoaded = false
    private var _isGenerating = false
    private var session: LanguageModelSession?
    private var generationTask: Task<Void, Never>?
    /// Tracks the system prompt used to create the current session, so we only
    /// recreate when the prompt actually changes.
    private var currentSystemPrompt: String?
    /// True when the session has no in-flight `ResponseStream`.
    ///
    /// `LanguageModelSession` asserts (SIGTRAP) if `streamResponse()` is called
    /// again before the previous `ResponseStream` has been fully consumed — i.e.
    /// its `AsyncIterator.next()` returned `nil`.  When a generation Task is
    /// cancelled mid-stream the iterator is dropped early, leaving the session in
    /// a "dirty" state.  This flag tracks that: it is cleared to `false` just
    /// before the streaming loop starts and restored to `true` only when the loop
    /// exits naturally (not via cancellation).  `generate()` treats a dirty session
    /// the same as a `nil` session and creates a fresh `LanguageModelSession`.
    private var _sessionIsClean = true

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Init

    public init() {}

    // MARK: - Test-only accessors

#if DEBUG
    /// Exposes the active session reference for unit tests that verify session reuse /
    /// recreation without running real inference. Not part of the public API.
    var _session: LanguageModelSession? { withStateLock { session } }

    /// Exposes the system prompt that was used to create the current session, so tests
    /// can assert that the tracking variable is updated correctly without inference.
    var _currentSystemPrompt: String? { withStateLock { currentSystemPrompt } }

    /// Forces `_isModelLoaded = true` without calling `loadModel()`.
    /// Lets unit tests exercise the session-creation branch inside `generate()` on CI
    /// runners that do not have Apple Intelligence available.
    func _forceLoaded() {
        withStateLock { _isModelLoaded = true }
    }

    /// Cancels the active generation task without calling `stopGeneration()`.
    ///
    /// Unlike `stopGeneration()`, this does NOT nil `session` or `currentSystemPrompt`
    /// synchronously.  `_sessionIsClean` is left for the Task body to manage: the
    /// cancelled Task will observe `Task.isCancelled` and leave `_sessionIsClean = false`
    /// when its streaming loop exits early.
    ///
    /// Use this in tests that need to stop a generation without going through the full
    /// `stopGeneration()` path.
    func _cancelTaskOnly() {
        let task = withStateLock { () -> Task<Void, Never>? in
            defer { generationTask = nil }
            return generationTask
        }
        task?.cancel()
    }

    /// Directly marks the session as dirty, simulating the state that results from a
    /// cancelled generation Task dropping its `ResponseStream` iterator mid-stream.
    ///
    /// Use this in unit tests that need to drive the `generate()` "dirty session →
    /// new LanguageModelSession" code path without racing against real Task scheduling.
    /// Prefer this over `_cancelTaskOnly()` when the test goal is to verify that the
    /// next `generate()` call creates a fresh session.
    func _markSessionDirty() {
        withStateLock { _sessionIsClean = false }
    }
#endif

    // MARK: - Availability

    /// Whether the system language model is available on this device.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        assert(plan.verdict != .deny,
               "ModelLoadPlan was denied; callers must check verdict before invoking backend")
        // Plan is informational for Foundation — the system owns all memory.
        unloadModel()

        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.inferenceFailure(
                "Apple Intelligence model is not available on this device"
            )
        }

        // Availability can report .available even when the session cannot
        // actually run inference (e.g. simulator, or Apple Intelligence not
        // fully set up). Probe with a minimal request to verify.
        //
        // Probe session history: `LanguageModelSession.respond(to:)` accumulates
        // conversation turns inside the session object. We must NOT store the probe
        // session as the backend's active session — if we did, the first real user
        // message would see the "Hi / <probe response>" exchange as prior context.
        // Instead we discard the probe session after the availability check; `generate()`
        // will create a fresh session on its first call (session == nil triggers that path).
        let probeSession = LanguageModelSession()
        do {
            _ = try await probeSession.respond(to: "Hi")
        } catch {
            Self.logger.warning("Foundation model probe failed: \(error)")
            throw InferenceError.inferenceFailure(
                "Apple Intelligence model is not ready. Ensure Apple Intelligence is enabled in Settings > Apple Intelligence & Siri."
            )
        }
        // Intentionally NOT assigning probeSession to self.session — see comment above.
        // session remains nil; generate() will create a clean session on first use.

        withStateLock {
            _isModelLoaded = true
        }
        Self.logger.info("Foundation backend loaded")
    }

    public func unloadModel() {
        stopGeneration()
        withStateLock {
            session = nil
            currentSystemPrompt = nil
            _isModelLoaded = false
            _isGenerating = false
            _sessionIsClean = true
        }
        Self.logger.info("Foundation backend unloaded")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        // Tool calling is synthesized via GuidedGeneration. The structured
        // schema is built up-front so a build failure (an unsupported
        // JSON-Schema construct in a registered tool) trips before we mutate
        // any session state — we fall back to plain generation in that case.
        let toolEnvelope: GenerationSchema?
        let toolsForRound: [ToolDefinition]
        let useToolPath = !config.tools.isEmpty && config.toolChoice != .none
        if useToolPath {
            do {
                toolEnvelope = try FoundationToolSchema.makeEnvelope(tools: config.tools)
                toolsForRound = config.tools
            } catch {
                // Most `Error`s do not carry a meaningful `localizedDescription`
                // unless they conform to `LocalizedError`. `String(describing:)`
                // preserves the keyword/type detail the schema builder embeds
                // in `FoundationToolSchemaError.description`.
                Self.logger.warning("FoundationBackend tool schema build failed; falling back to text-only: \(String(describing: error), privacy: .public)")
                toolEnvelope = nil
                toolsForRound = []
            }
        } else {
            toolEnvelope = nil
            toolsForRound = []
        }

        // The tool envelope contract is taught to the model via instructions.
        // `LanguageModelSession(instructions:)` bakes the prompt into the
        // session; we therefore need a session whose instructions reflect
        // both the host's system prompt AND (for the tooled path) the tool
        // catalogue. The two halves are concatenated so a session-cache hit
        // requires both halves to match what's already loaded.
        let effectiveInstructions: String? = {
            let suffix = toolsForRound.isEmpty
                ? nil
                : FoundationToolSchema.instructions(tools: toolsForRound)
            switch (systemPrompt, suffix) {
            case (nil, nil): return nil
            case (let s?, nil): return s
            case (nil, let t?): return t
            case (let s?, let t?): return s + "\n\n" + t
            }
        }()

        let activeSession: LanguageModelSession = try withStateLock {
            guard _isModelLoaded else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            _isGenerating = true

            // Reuse the existing session to preserve conversation history.
            // Recreate if: no session exists, the system prompt changed, or the
            // previous generation was cancelled before its ResponseStream was fully
            // consumed.  In the last case the session is "dirty" — LanguageModelSession
            // asserts (SIGTRAP) if streamResponse() is called on a session whose
            // previous ResponseStream iterator was dropped before returning nil.
            let needsNewSession = session == nil
                || effectiveInstructions != currentSystemPrompt
                || !_sessionIsClean
            if needsNewSession {
                if let effectiveInstructions, !effectiveInstructions.isEmpty {
                    session = LanguageModelSession(instructions: effectiveInstructions)
                } else {
                    session = LanguageModelSession()
                }
                currentSystemPrompt = effectiveInstructions
                _sessionIsClean = true  // fresh session always starts clean
            }

            return session!
        }

        Self.logger.debug("Foundation generate started (tools=\(toolsForRound.count, privacy: .public))")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        let task = Task { [weak self, generationStream] in
            guard let backend = self else {
                continuation.finish()
                return
            }

            defer {
                backend.withStateLock {
                    backend._isGenerating = false
                    backend.generationTask = nil
                }
                Self.logger.debug("Foundation generate finished")
            }

            do {
                var options = GenerationOptions()
                options.temperature = Double(config.temperature)

                // Mark the session as dirty before iterating.  If the Task is
                // cancelled or the loop breaks early (e.g. output token limit) before
                // the ResponseStream is fully consumed, the session will be considered
                // dirty and generate() will create a fresh LanguageModelSession on the
                // next call.  This prevents a SIGTRAP: LanguageModelSession asserts when
                // streamResponse() is called again while the previous ResponseStream
                // iterator was dropped before returning nil.
                backend.withStateLock { backend._sessionIsClean = false }

                let streamExhausted: Bool
                if let toolEnvelope {
                    streamExhausted = try await backend.runToolAwareStream(
                        session: activeSession,
                        prompt: prompt,
                        schema: toolEnvelope,
                        options: options,
                        continuation: continuation,
                        generationStream: generationStream
                    )
                } else {
                    streamExhausted = try await backend.runTextOnlyStream(
                        session: activeSession,
                        prompt: prompt,
                        options: options,
                        outputLimit: config.maxOutputTokens,
                        continuation: continuation,
                        generationStream: generationStream
                    )
                }

                // Only mark the session clean when the ResponseStream was fully
                // consumed (iterator returned nil).  Any early exit — task
                // cancellation or output-token-limit break — leaves the iterator
                // dropped mid-stream, which would cause LanguageModelSession to
                // SIGTRAP on the next streamResponse() call.
                if streamExhausted {
                    backend.withStateLock { backend._sessionIsClean = true }
                }
                await MainActor.run { generationStream.setPhase(.done) }
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("Foundation generation error: \(error)")
                    await MainActor.run { generationStream.setPhase(.failed(error.localizedDescription)) }
                    continuation.finish(throwing: error)
                    return
                }
                await MainActor.run { generationStream.setPhase(.done) }
            }

            continuation.finish()
        }

        withStateLock {
            generationTask = task
        }

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return generationStream
    }

    // MARK: - Streaming helpers

    /// Default text-only streaming path. Returns `true` iff the response
    /// stream was fully consumed (iterator returned `nil`).
    private func runTextOnlyStream(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        outputLimit: Int?,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        generationStream: GenerationStream
    ) async throws -> Bool {
        let responseStream = session.streamResponse(to: prompt, options: options)

        var outputTokenCount = 0
        var previousCount = 0
        var isFirstToken = true
        var streamExhausted = true
        for try await partial in responseStream {
            if Task.isCancelled {
                streamExhausted = false
                break
            }

            let currentText = partial.content
            if currentText.count > previousCount {
                let newContent = String(currentText.dropFirst(previousCount))
                if isFirstToken {
                    await MainActor.run { generationStream.setPhase(.streaming) }
                    isFirstToken = false
                }
                continuation.yield(.token(newContent))
                previousCount = currentText.count

                // Approximate token count using the conservative 3-char heuristic.
                // Stops runaway generation for open-ended prompts.
                if let outputLimit {
                    outputTokenCount += max(1, newContent.count / 3)
                    if outputTokenCount >= outputLimit {
                        Self.logger.info("Output token limit (\(outputLimit)) reached")
                        streamExhausted = false
                        break
                    }
                }
            }
        }
        return streamExhausted
    }

    /// Tool-aware streaming path. Drives generation against the
    /// `(text|tool_call)` envelope schema. While the partially-generated
    /// envelope's `kind` is `"text"` we forward the growing `text` field as
    /// `.token` deltas so existing UI streams smoothly. On stream completion
    /// we inspect the final `GeneratedContent` and emit either a single
    /// `.toolCall(...)` event (tool branch) or nothing more (text branch —
    /// already streamed). Returns `true` iff the response stream was fully
    /// consumed.
    private func runToolAwareStream(
        session: LanguageModelSession,
        prompt: String,
        schema: GenerationSchema,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        generationStream: GenerationStream
    ) async throws -> Bool {
        let responseStream = session.streamResponse(
            to: prompt,
            schema: schema,
            includeSchemaInPrompt: true,
            options: options
        )

        var lastTextLength = 0
        var streamedAsText = false
        var isFirstToken = true
        var finalRaw: GeneratedContent?
        var streamExhausted = true

        for try await snapshot in responseStream {
            if Task.isCancelled {
                streamExhausted = false
                break
            }
            finalRaw = snapshot.rawContent

            // Try to extract the streaming text branch progressively. The
            // structured generator emits the JSON envelope token-by-token, so
            // partial snapshots may carry an incomplete `text` field — that's
            // fine, we forward whatever new suffix is present.
            if case .structure(let props, _) = snapshot.rawContent.kind,
               case .string(let kindStr)? = props["kind"]?.kind,
               kindStr == "text",
               case .string(let textSoFar)? = props["text"]?.kind {
                if textSoFar.count > lastTextLength {
                    let delta = String(textSoFar.dropFirst(lastTextLength))
                    if isFirstToken {
                        await MainActor.run { generationStream.setPhase(.streaming) }
                        isFirstToken = false
                    }
                    continuation.yield(.token(delta))
                    lastTextLength = textSoFar.count
                    streamedAsText = true
                }
            }
        }

        guard streamExhausted, let finalRaw else {
            return streamExhausted
        }

        // Decode the final envelope and dispatch on the branch the model picked.
        guard let envelope = FoundationEnvelope.decode(finalRaw) else {
            // Best-effort fallback: surface the raw JSON as text rather than
            // dropping the round on the floor. The orchestrator will treat
            // this as a finished text reply. Phase must transition before the
            // first event is yielded so observers don't briefly see tokens
            // arriving while still in `.connecting`.
            if !streamedAsText {
                await MainActor.run { generationStream.setPhase(.streaming) }
                continuation.yield(.token(finalRaw.jsonString))
            }
            Self.logger.warning("FoundationBackend: envelope decode failed; surfaced raw JSON as text")
            return streamExhausted
        }

        switch envelope {
        case .text(let final):
            // If we never streamed (e.g. the structured generator delivered
            // the whole envelope in one snapshot), emit the full text now.
            if !streamedAsText {
                if isFirstToken {
                    await MainActor.run { generationStream.setPhase(.streaming) }
                }
                continuation.yield(.token(final))
            }
        case .toolCall(let name, let argumentsJSON):
            // The tool branch can produce zero `.token` events when the model
            // commits to a tool call straight away. Transition to `.streaming`
            // before the `.toolCall` event so observers don't stay stuck in
            // `.connecting` until `.done` — mirrors MLXBackend, which treats
            // `.toolCall` as a streaming event.
            if isFirstToken {
                await MainActor.run { generationStream.setPhase(.streaming) }
                isFirstToken = false
            }
            let call = ToolCall(
                id: "fm-\(UUID().uuidString)",
                toolName: name,
                arguments: argumentsJSON
            )
            continuation.yield(.toolCall(call))
        }

        return streamExhausted
    }

    // MARK: - Conversation Reset

    public func resetConversation() {
        withStateLock {
            session = nil
            currentSystemPrompt = nil
            _sessionIsClean = true
        }
        Self.logger.info("Foundation conversation reset")
    }

    // MARK: - Control

    public func stopGeneration() {
        let task = withStateLock { () -> Task<Void, Never>? in
            defer { generationTask = nil }
            return generationTask
        }
        task?.cancel()

        // Discard the session after cancellation so the partial response
        // doesn't corrupt the conversation history for subsequent turns.
        withStateLock {
            session = nil
            currentSystemPrompt = nil
            _sessionIsClean = true
        }
    }

}

// MARK: - TokenizerVendor

@available(iOS 26, macOS 26, *)
extension FoundationBackend: TokenizerVendor {
    /// Vends a synchronous tokenizer using a conservative 3-chars-per-token heuristic
    /// calibrated for Apple's Foundation Model tokenizer (which produces more tokens
    /// per character than the default 4-char heuristic).
    public var tokenizer: any TokenizerProvider { FoundationTokenizer.shared }
}

/// Conservative synchronous tokenizer for Apple Foundation Models.
///
/// Apple's tokenizer produces roughly 1 token per 2.5-3 characters for English text.
/// Using 3 chars/token is a safe estimate that slightly overestimates token usage,
/// which is preferable to underestimating and hitting context overflow errors.
@available(iOS 26, macOS 26, *)
struct FoundationTokenizer: TokenizerProvider {
    static let shared = FoundationTokenizer()
    func tokenCount(_ text: String) -> Int {
        max(1, text.count / 3)
    }
}
#endif
