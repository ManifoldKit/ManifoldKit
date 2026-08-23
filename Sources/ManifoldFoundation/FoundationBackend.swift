#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os
// P2a (#1719): the Foundation Models bridge compiles against the Contract leaf
// surface only (InferenceBackend, GenerationConfig, GenerationEvent, …) — no
// engine state. ManifoldContract re-exports the P1 leaf types it needs.
import ManifoldContract
// InferenceMetricSink and InMemoryMetricSink live in ManifoldInference since
// the observability train relocated them from ManifoldCloudCore so that this
// backend can reach them without a ManifoldCloudCore dependency.
import ManifoldInference

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
/// ManifoldKit surfaces reasoning tokens from capable models via
/// ``GenerationEvent/thinkingToken(_:)`` and ``GenerationEvent/thinkingCompleted``.
/// The Ollama and Llama backends emit these events today. **FoundationBackend
/// does not.** In the Xcode 26 SDK used by the backend's minimum supported
/// runtime, FoundationModels exposes no reasoning/thinking surface:
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
/// Xcode 27 adds reasoning transcript entries and a reasoning-level option.
/// Those APIs are not bridged yet: the backend retains its Xcode 26 behavior
/// and does not claim ``BackendCapabilities/supportsThinking``. A future bridge
/// must map the SDK 27 stream into `.thinkingToken` / `.thinkingCompleted`
/// without changing the iOS 26 / macOS 26 path or exposing private reasoning
/// as ordinary visible content.
///
/// ## Multimodal / vision support
///
/// ManifoldKit surfaces image attachments via ``MessagePart/image(data:mimeType:)``
/// and gates UI affordances on ``BackendCapabilities/supportsVision``. The
/// MLX, Claude, and OpenAI backends accept image input today; **FoundationBackend
/// does not.** The Xcode 26 FoundationModels API used by the minimum supported
/// runtime has no image-input surface:
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
/// Xcode 27 adds attachment/image prompt APIs and runtime vision capability
/// reporting. They are not bridged yet, so the backend intentionally continues
/// to advertise ``BackendCapabilities/supportsVision`` as `false`; the runtime
/// rejects image-bearing turns before building a request. Issue #1710 tracks a
/// guarded SDK 27 translation while preserving the Xcode 26 implementation.
@available(iOS 26, macOS 26, *)
public final class FoundationBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
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
        // Xcode 27 ships attachment/image prompt APIs, but this backend still
        // supports Xcode and runtimes 26. Keep the claim false until #1710 adds
        // a compiler- and runtime-guarded translation plus live device proof.
        // Flipping this flag auto-enables the composer's PhotoAttachmentButton /
        // VisionInputButton (they gate on BackendCapabilities.supportsVision).
        supportsVision: false,
        // Whole-call emission only — Apple's GuidedGeneration streams the
        // partially-decoded structure but we do not surface name/argument
        // deltas as separate events (parity with MLXBackend's inline parser).
        streamsToolCallArguments: false,
        // #2354: `.guided` is now wired end-to-end. `respond`/`structured` stage
        // `.guided(T.self)`; `GenerationQueue.structuredOutputTarget(from:capabilities:)`
        // builds a full target from it; and `generate()` below reads
        // `hints.structuredOutput` and drives native GuidedGeneration via
        // `FoundationToolSchema.mapJSONSchema` (the same JSON-Schema →
        // `DynamicGenerationSchema` mapper the tool-calling path already used).
        // Behavioral proof: `test_guidedStructuredOutput_...` in the Foundation
        // conformance suite decodes a real guided round-trip into a concrete type
        // — not `claimWithoutBehaviouralAssertion`.
        supportsGuidedStructuredOutput: true,
        // `requiresPromptTemplate` is `false`: the FoundationModels SDK applies
        // its own chat template internally and we hand it the conversation as a
        // structured `Transcript`/`Prompt`, never a single templated string.
        // GenerationQueue therefore captures only the latest user message into
        // `.promptRendered`, so the rendered prompt is a partial view (#1905).
        rendersFullPrompt: false,
        // Apple's on-device model degrades sharply once the tool catalogue
        // exceeds ~16 entries — the schema definitions consume an increasing
        // fraction of its fixed context budget. Advertising more than 16 tools
        // would leave less room for user content and reduce reasoning quality.
        // ConversationTurnExecutor reads this cap and truncates the
        // `GenerationConfig.tools` list before each turn.
        maxAdvertisedToolCount: 16
    )

    // MARK: - Private

    private let stateLock = NSLock()
    private var _isModelLoaded = false
    private var _isGenerating = false
    private var session: LanguageModelSession?
    private var generationTask: Task<Void, Never>?
    private var generationSequence: UInt64 = 0
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

    /// Closure that returns the current `SystemLanguageModel.Availability`.
    /// Injected at init so unit tests can drive the unavailable branch without a
    /// real Apple Intelligence entitlement. Production uses the system default.
    private let availabilityResolver: @Sendable () -> SystemLanguageModel.Availability

    /// The sink that receives an ``InferenceMetric`` after every generation call.
    ///
    /// Defaults to ``InMemoryMetricSink/shared`` so callers can read recent
    /// metrics without any configuration. Set to `nil` to disable metric emission.
    public var metricSink: (any InferenceMetricSink)? = InMemoryMetricSink.shared

    /// Optional vendor-neutral trace sink for OpenTelemetry-compatible span export.
    ///
    /// When set, each completed generation emits a ``GenSpan`` of kind ``SpanKind/llm``
    /// alongside the flat ``InferenceMetric``. Defaults to `nil` (no span export).
    public var traceSink: (any TraceSink)?

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Init

    public init() {
        self.availabilityResolver = { SystemLanguageModel.default.availability }
    }

    /// Designated init for testing — allows injecting a stub availability resolver
    /// so the unavailable branch in `loadModel` can be exercised without a real
    /// Apple Intelligence entitlement.
    init(availabilityResolver: @escaping @Sendable () -> SystemLanguageModel.Availability) {
        self.availabilityResolver = availabilityResolver
    }

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

    /// Structured, OS-agnostic reason describing Foundation availability.
    ///
    /// Convenience alias for ``FoundationAvailability/reason`` exposed on the
    /// backend so hosts can read a UI-drivable reason (`.deviceNotEligible` vs
    /// `.appleIntelligenceNotEnabled` vs `.modelNotReady`, …) without importing
    /// `FoundationModels` or writing `#available` guards. Reachable here only
    /// when the SDK and OS are present; prefer ``FoundationAvailability/reason``
    /// from host code so the call site compiles on any deployment target
    /// (it collapses to `.unsupportedOS` / `.notBuilt` off-platform).
    public static var availabilityReason: FoundationAvailabilityReason {
        FoundationAvailability.reason
    }

    /// Whether the system language model is available according to this backend's
    /// injected availability resolver. Equals `FoundationBackend.isAvailable` in
    /// production; can differ in tests that inject a stub resolver.
    var isAvailableViaProvider: Bool {
        availabilityResolver() == .available
    }

    /// Probes the model with a minimal request to confirm it can serve inference.
    ///
    /// `isAvailable` can return `true` while the model isn't fully downloaded or
    /// Apple Intelligence isn't configured in System Settings. Use this in async
    /// test setUp methods to produce a clear XCTSkip rather than a cryptic runtime
    /// failure.
    public static func probeIsReady() async -> Bool {
        guard isAvailable else { return false }
        let probe = LanguageModelSession()
        do {
            _ = try await probe.respond(to: "Hi")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        assert(plan.verdict != .deny,
               "ModelLoadPlan was denied; callers must check verdict before invoking backend")
        // Plan is informational for Foundation — the system owns all memory.
        unloadModel()

        guard availabilityResolver() == .available else {
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

    /// Asynchronous shutdown that awaits the in-flight generation Task before
    /// returning. Use in test teardown to deterministically release the
    /// captured `LanguageModelSession` so the next test's `probeIsReady()`
    /// doesn't race against a still-live session from the previous test.
    ///
    /// `unloadModel()` cancels the generation Task but returns synchronously,
    /// so the Task body — which holds a local strong reference to the active
    /// `LanguageModelSession` — may still be running when the next test starts.
    /// On Apple Intelligence-equipped hosts the next test's `probeIsReady()`
    /// can observe the prior session as active and skip with "not ready",
    /// surfacing as the cross-test flake tracked in #1319 / #1115.
    ///
    /// One `await Task.yield()` (the previous teardown shape) is not a
    /// sufficient barrier — `LanguageModelSession.streamResponse` work hops
    /// off-actor through the system daemon, so a single cooperative yield
    /// can return before the cancelled body finishes its `defer` block.
    public func unloadModelAndWait() async {
        let task = withStateLock { () -> Task<Void, Never>? in
            let snapshot = generationTask
            return snapshot
        }
        unloadModel()
        // Awaiting the cancelled Task's value waits for its `defer` block to
        // run, which is what drops the local `activeSession` strong reference.
        await task?.value
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        // Fail closed on grammar-constrained sampling. Apple's FoundationModels
        // SDK exposes no GBNF/grammar surface, so a non-nil grammar cannot be
        // honoured — silently dropping it would turn a guaranteed-valid
        // expectation into an unchecked one (see the InferenceBackend contract
        // on `GenerationConfig.grammar`). Mirrors the central SSECloudBackend
        // check. Checked before the
        // model-loaded guard so a misconfigured request fails fast regardless of
        // load state, and gated on the capability flag so a future SDK that adds
        // grammar support relaxes this automatically when the flag flips true.
        if config.grammar != nil, !capabilities.supportsGrammarConstrainedSampling {
            throw InferenceError.unsupportedGrammar(
                reason: "FoundationBackend does not support grammar-constrained sampling."
            )
        }

        // Prior-turn image parts arrive per-call on `hints.history` (#2312).
        // `LanguageModelSession` replays the *text* of prior turns from its own
        // internal transcript, so this is purely the multimodal seam — a
        // documented NO-OP on the current toolchain (see below).
        installImageAttachments(from: hints.history)

        // Tool calling is synthesized via GuidedGeneration. The structured
        // schema is built up-front so a build failure (an unsupported
        // JSON-Schema construct in a registered tool) trips before we mutate
        // any session state.
        //
        // ToolChoice forcing: `.required` and `.tool(name:)` are honoured by
        // restricting the envelope schema — `.required` drops the plain-text arm
        // so the model must pick a tool; `.tool(name:)` restricts the tool arms
        // to just the named tool. A forcing request we cannot honour (unknown
        // named tool, or a forced tool whose parameter schema won't build) fails
        // closed rather than silently downgrading to model-decides — matching
        // the grammar contract above. `.auto` still degrades to text-only when a
        // tool schema won't build, since text is an acceptable answer there.
        let toolEnvelope: GenerationSchema?
        let toolsForRound: [ToolDefinition]
        let useToolPath = !config.tools.isEmpty && config.toolChoice != .none
        if useToolPath {
            let selection: FoundationToolSchema.ToolSelection
            do {
                selection = try FoundationToolSchema.resolveToolSelection(
                    tools: config.tools,
                    toolChoice: config.toolChoice
                )
            } catch {
                // Only an unsatisfiable forcing request (e.g. `.tool(name:)`
                // naming a tool absent from the list) throws here. Fail closed:
                // answering with free text would ignore the caller's demand.
                throw InferenceError.inferenceFailure(
                    "FoundationBackend cannot honour the requested toolChoice: \(String(describing: error))"
                )
            }

            do {
                toolEnvelope = try FoundationToolSchema.makeEnvelope(selection: selection)
                toolsForRound = selection.tools
            } catch {
                // Most `Error`s do not carry a meaningful `localizedDescription`
                // unless they conform to `LocalizedError`. `String(describing:)`
                // preserves the keyword/type detail the schema builder embeds
                // in `FoundationToolSchemaError.description`.
                if config.toolChoice == .auto {
                    Self.logger.warning("FoundationBackend tool schema build failed; falling back to text-only: \(String(describing: error), privacy: .public)")
                    toolEnvelope = nil
                    toolsForRound = []
                } else {
                    // A forced round cannot degrade to text — that would ignore
                    // `.required` / `.tool(name:)`. Fail closed.
                    throw InferenceError.inferenceFailure(
                        "FoundationBackend cannot honour the requested toolChoice because a forced tool's parameter schema is unsupported: \(String(describing: error))"
                    )
                }
            }
        } else {
            toolEnvelope = nil
            toolsForRound = []
        }

        // Guided structured output (#2354). Mutually exclusive with the tool
        // path above — a request carrying both `config.tools` and a guided
        // `hints.structuredOutput` target is a caller error the tool path
        // already wins by construction (tool calling never routes through
        // `hints.structuredOutput`), so guided lowering only applies when the
        // tool path didn't already claim the round.
        //
        // Built up-front, like the tool envelope, so an unsupported JSON-Schema
        // construct in the target type fails before any session state mutates.
        // Unlike the tool path's `.auto`-only fallback, there is no "acceptable
        // downgrade" here: the caller explicitly asked for `T` back, so a schema
        // that won't build fails closed rather than silently degrading to text
        // the caller's `decodeAndValidate` would then fail to parse anyway with
        // a far more confusing error.
        let guidedSchema: GenerationSchema?
        if toolEnvelope == nil, case .guided(let guidedType)? = hints.structuredOutput {
            // `respond`/`structured` (ManifoldInference) only ever stage
            // `.guided` for a concrete `T: SchemaProviding` — the generic
            // constraint guarantees this cast succeeds for every real caller.
            // Failing closed rather than crashing is defensive against a
            // hypothetical future caller staging `.guided` without it.
            guard let provider = guidedType as? any SchemaProviding.Type else {
                throw InferenceError.inferenceFailure(
                    "FoundationBackend cannot honour guided structured output for \(String(describing: guidedType)): the type does not conform to SchemaProviding."
                )
            }
            do {
                guidedSchema = try FoundationToolSchema.makeGuidedSchema(
                    from: provider.jsonSchema,
                    typeName: String(describing: guidedType)
                )
            } catch {
                throw InferenceError.inferenceFailure(
                    "FoundationBackend cannot honour guided structured output for \(String(describing: guidedType)): \(String(describing: error))"
                )
            }
        } else {
            guidedSchema = nil
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

        let (activeSession, generationID): (LanguageModelSession, UInt64) = try withStateLock {
            guard _isModelLoaded else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            generationSequence &+= 1
            let generationID = generationSequence
            _isGenerating = true

            // Reuse the existing session to preserve conversation history.
            // Recreate if: no session exists, the system prompt changed, or the
            // previous generation was cancelled before its ResponseStream was fully
            // consumed.  In the last case the session is "dirty" — LanguageModelSession
            // asserts (SIGTRAP) if streamResponse() is called on a session whose
            // previous ResponseStream iterator was dropped before returning nil.
            let needsNewSession = needsNewFoundationSession(
                sessionExists: session != nil,
                currentInstructions: currentSystemPrompt,
                newInstructions: effectiveInstructions,
                isClean: _sessionIsClean
            )
            if needsNewSession {
                if let effectiveInstructions, !effectiveInstructions.isEmpty {
                    session = LanguageModelSession(instructions: effectiveInstructions)
                } else {
                    session = LanguageModelSession()
                }
                currentSystemPrompt = effectiveInstructions
                _sessionIsClean = true  // fresh session always starts clean
                // Signal the system daemon to warm up KV-cache state so the
                // first streamResponse() on this session pays less IPC setup.
                session?.prewarm()
            }

            return (session!, generationID)
        }

        Self.logger.debug("Foundation generate started (tools=\(toolsForRound.count, privacy: .public))")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        // Strong capture of `self` is intentional: the generation Task owns the
        // stream's lifetime and must run to completion (or explicit cancellation
        // via `stopGeneration()`) regardless of external retain-count changes.
        // Weak capture would silently drop the entire generation — emitting zero
        // events — if ARC happened to release the backend between `generate()`
        // returning and the Task being scheduled by the cooperative executor.
        // The retain cycle (backend → generationTask → backend) is broken in the
        // `defer` block when `generationTask` is nilled out on completion.
        let metricTracker = GenerationMetricTracker()
        let capturedMetricSink = withStateLock { metricSink }
        let capturedTraceSink = withStateLock { traceSink }
        let task = Task { [self, generationStream] in
            var streamError: Error?
            defer {
                withStateLock {
                    if generationSequence == generationID {
                        _isGenerating = false
                        generationTask = nil
                    }
                }
                // Emit an InferenceMetric (and optional GenSpan) after every
                // generation (success or failure). Foundation Models does not
                // expose token-level usage, so prompt/completion counts are zero.
                let errorClass = streamError.map { String(describing: type(of: $0)) }
                if capturedMetricSink != nil || capturedTraceSink != nil {
                    let metric = metricTracker.buildMetric(
                        provider: "FoundationModels",
                        model: "apple-foundation",
                        promptTokens: 0,
                        cachedPromptTokens: 0,
                        completionTokens: 0,
                        errorClass: errorClass
                    )
                    if let sink = capturedMetricSink { Task { await sink.record(metric) } }
                    if let sink = capturedTraceSink { Task { await sink.record(metric.asGenSpan()) } }
                }
                Self.logger.debug("Foundation generate finished")
            }

            do {
                var options = GenerationOptions()
                if config.temperature == 0 {
                    #if compiler(>=6.4)
                    options.samplingMode = .greedy
                    #else
                    options.sampling = .greedy
                    #endif
                } else {
                    options.temperature = Double(config.temperature)
                }
                if let maxTokens = config.maxOutputTokens {
                    options.maximumResponseTokens = maxTokens
                }

                // Mark the session as dirty before iterating.  If the Task is
                // cancelled or the loop breaks early (e.g. output token limit) before
                // the ResponseStream is fully consumed, the session will be considered
                // dirty and generate() will create a fresh LanguageModelSession on the
                // next call.  This prevents a SIGTRAP: LanguageModelSession asserts when
                // streamResponse() is called again while the previous ResponseStream
                // iterator was dropped before returning nil.
                withStateLock { _sessionIsClean = false }

                metricTracker.start()

                let result: StreamResult
                if let toolEnvelope {
                    result = try await runToolAwareStream(
                        session: activeSession,
                        prompt: prompt,
                        schema: toolEnvelope,
                        options: options,
                        continuation: continuation,
                        generationStream: generationStream,
                        metricTracker: capturedMetricSink != nil ? metricTracker : nil
                    )
                } else if let guidedSchema {
                    result = try await runGuidedStructuredStream(
                        session: activeSession,
                        prompt: prompt,
                        schema: guidedSchema,
                        options: options,
                        continuation: continuation,
                        generationStream: generationStream,
                        metricTracker: capturedMetricSink != nil ? metricTracker : nil
                    )
                } else {
                    result = try await runTextOnlyStream(
                        session: activeSession,
                        prompt: prompt,
                        options: options,
                        continuation: continuation,
                        generationStream: generationStream,
                        metricTracker: capturedMetricSink != nil ? metricTracker : nil
                    )
                }

                // Only mark the session clean when the ResponseStream was fully
                // consumed (iterator returned nil).  Any early exit — task
                // cancellation or output-token-limit break — leaves the iterator
                // dropped mid-stream, which would cause LanguageModelSession to
                // SIGTRAP on the next streamResponse() call.
                if result.streamExhausted {
                    withStateLock { _sessionIsClean = true }
                }

                // Detect silent zero-event completion: Foundation Models can return
                // an empty ResponseStream when the device is locked, Apple Intelligence
                // is busy, or the on-device model is temporarily unavailable.  Without
                // this check the consumer's for-try-await loop exits immediately with
                // no tokens and no error — indistinguishable from "generation worked
                // but produced nothing", the worst kind of silent failure.
                //
                // Only fire on a natural exhaustion (not mid-stream cancellation) so
                // we don't misfire when the caller calls stopGeneration() before the
                // first token arrives.
                if result.streamExhausted && result.eventsEmitted == 0 && !Task.isCancelled {
                    let msg = "Foundation Models returned an empty response. " +
                        "Ensure Apple Intelligence is enabled, the device is unlocked, " +
                        "and the model is fully downloaded in Settings > Apple Intelligence & Siri."
                    Self.logger.warning("\(msg, privacy: .public)")
                    let err = InferenceError.inferenceFailure(msg)
                    await MainActor.run { generationStream.setPhase(.failed(msg)) }
                    continuation.finish(throwing: err)
                    return
                }

                await MainActor.run { generationStream.setPhase(.done) }
            } catch {
                streamError = error
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

    /// Carries the outcome of a streaming helper back to the generation Task.
    private struct StreamResult {
        /// Whether the ResponseStream was fully consumed (iterator returned `nil`).
        /// `false` means the loop broke early — task cancellation or output cap.
        let streamExhausted: Bool
        /// Total number of stream events (tokens or tool calls) emitted into the
        /// continuation. Used to detect silent zero-event completions.
        let eventsEmitted: Int
    }

    /// Default text-only streaming path.
    private func runTextOnlyStream(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        generationStream: GenerationStream,
        metricTracker: GenerationMetricTracker?
    ) async throws -> StreamResult {
        let responseStream = session.streamResponse(to: prompt, options: options)

        var previousCount = 0
        var isFirstToken = true
        var streamExhausted = true
        var eventsEmitted = 0
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
                metricTracker?.recordToken()
                continuation.yield(.token(newContent))
                eventsEmitted += 1
                previousCount = currentText.count
            }
        }
        return StreamResult(streamExhausted: streamExhausted, eventsEmitted: eventsEmitted)
    }

    /// Tool-aware streaming path. Drives generation against the
    /// `(text|tool_call)` envelope schema. While the partially-generated
    /// envelope's `kind` is `"text"` we forward the growing `text` field as
    /// `.token` deltas so existing UI streams smoothly. On stream completion
    /// we inspect the final `GeneratedContent` and emit either a single
    /// `.toolCall(...)` event (tool branch) or nothing more (text branch —
    /// already streamed).
    private func runToolAwareStream(
        session: LanguageModelSession,
        prompt: String,
        schema: GenerationSchema,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        generationStream: GenerationStream,
        metricTracker: GenerationMetricTracker?
    ) async throws -> StreamResult {
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
        var eventsEmitted = 0

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
                    metricTracker?.recordToken()
                    continuation.yield(.token(delta))
                    eventsEmitted += 1
                    lastTextLength = textSoFar.count
                    streamedAsText = true
                }
            }
        }

        guard streamExhausted, let finalRaw else {
            return StreamResult(streamExhausted: streamExhausted, eventsEmitted: eventsEmitted)
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
                eventsEmitted += 1
            }
            Self.logger.warning("FoundationBackend: envelope decode failed; surfaced raw JSON as text")
            return StreamResult(streamExhausted: streamExhausted, eventsEmitted: eventsEmitted)
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
                eventsEmitted += 1
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
            eventsEmitted += 1
        }

        return StreamResult(streamExhausted: streamExhausted, eventsEmitted: eventsEmitted)
    }

    /// Guided structured-output streaming path (#2354). Drives generation
    /// against the caller's target-type schema directly — no `(text|tool_call)`
    /// envelope union, since a guided request has exactly one shape to fill.
    ///
    /// Whole-call emission only, matching `streamsToolCallArguments: false`
    /// above: progressively emitting `.jsonString` deltas of a partially-decoded
    /// arbitrary object is not the same safe operation as streaming a single
    /// string field (the tool envelope's `text` branch) — a partial snapshot's
    /// serialization can restructure as sibling fields resolve, not just grow
    /// by suffix. `respond`/`structured` only need the complete text to decode
    /// `T` from, so correctness (not streaming granularity) is what matters
    /// here; the whole JSON is yielded as one `.token` once the stream drains.
    private func runGuidedStructuredStream(
        session: LanguageModelSession,
        prompt: String,
        schema: GenerationSchema,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        generationStream: GenerationStream,
        metricTracker: GenerationMetricTracker?
    ) async throws -> StreamResult {
        let responseStream = session.streamResponse(
            to: prompt,
            schema: schema,
            includeSchemaInPrompt: true,
            options: options
        )

        var finalRaw: GeneratedContent?
        var streamExhausted = true
        for try await snapshot in responseStream {
            if Task.isCancelled {
                streamExhausted = false
                break
            }
            finalRaw = snapshot.rawContent
            metricTracker?.recordToken()
        }

        guard streamExhausted, let finalRaw else {
            return StreamResult(streamExhausted: streamExhausted, eventsEmitted: 0)
        }

        await MainActor.run { generationStream.setPhase(.streaming) }
        continuation.yield(.token(finalRaw.jsonString))
        return StreamResult(streamExhausted: streamExhausted, eventsEmitted: 1)
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
            generationSequence &+= 1
            let task = generationTask
            generationTask = nil
            _isGenerating = false
            // Discard the session after cancellation so the partial response
            // doesn't corrupt the conversation history for subsequent turns.
            session = nil
            currentSystemPrompt = nil
            _sessionIsClean = true
            return task
        }
        task?.cancel()
    }

}

// MARK: - Multimodal history seam

@available(iOS 26, macOS 26, *)
extension FoundationBackend {
    /// Image-attachment seam for prior-turn ``MessagePart/image`` parts.
    ///
    /// This is a deliberate NO-OP on the current toolchain (Xcode 26.x /
    /// Swift 6.2.x). Apple's public FoundationModels SDK exposes no `Data` /
    /// `CGImage` / `Attachment` ingress for the model — see the
    /// ``FoundationBackend`` type-level doc comment for the full audit. We do
    /// NOT reference any 27.0-only symbol (`Attachment`, image-bearing
    /// `Prompt` initialisers, etc.) so this compiles cleanly today.
    ///
    /// When the multimodal SDK lands (WWDC 2026 AFM 3, tracked by #1710), the
    /// flag flip is a small, localized change:
    ///   1. Gate the body on the real availability, e.g.
    ///      `if #available(iOS 26.4, macOS 26.4, *) { … }`.
    ///   2. For each ``StructuredMessage`` whose ``StructuredMessage/parts``
    ///      contain a ``MessagePart/image(data:mimeType:)``, build an
    ///      `Attachment` from the image bytes and thread it into the prompt /
    ///      session transcript.
    ///   3. Flip ``BackendCapabilities/supportsVision`` to the runtime-conditional
    ///      `true` (see the OUTSTANDING note on `capabilities`).
    /// The structured history this reads from is already wired (above), so the
    /// only change at that point is replacing this NO-OP body.
    private func installImageAttachments(from messages: [StructuredMessage]) {
        // Intentionally empty on the current toolchain. The presence of image
        // parts is detected by the runtime's GenerationQueue pre-flight, which
        // rejects image-bearing turns while `supportsVision == false`; this
        // backend therefore never receives images to install today.
        _ = messages
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

// MARK: - Session predicate

/// Returns `true` when `generate()` must allocate a fresh `LanguageModelSession`.
///
/// Extracted as a file-private pure function so tests can cover all four branches
/// without requiring a real Apple Intelligence entitlement.
///
/// - Parameters:
///   - sessionExists: Whether a session has already been created.
///   - currentInstructions: The instructions that were used to create the current session.
///   - newInstructions: The instructions required for the upcoming generation turn.
///   - isClean: `true` when the current session's `ResponseStream` was fully consumed
///     (iterator returned `nil`). `false` means the stream was abandoned mid-flight;
///     reusing it would cause `LanguageModelSession` to SIGTRAP on the next
///     `streamResponse()` call.
func needsNewFoundationSession(
    sessionExists: Bool,
    currentInstructions: String?,
    newInstructions: String?,
    isClean: Bool
) -> Bool {
    !sessionExists || currentInstructions != newInstructions || !isClean
}

#endif
