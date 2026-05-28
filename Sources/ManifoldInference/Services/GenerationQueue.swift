import Foundation
import Observation

/// FIFO + priority queue and tool-dispatch transport for generation requests.
///
/// `GenerationQueue` owns the generation queue, in-flight request tracking,
/// prompt formatting, the per-token thermal-pause loop, and the tool-call
/// dispatch transport that ``ConversationRuntime`` runs on top of. It is an
/// internal implementation detail of `ManifoldInference`; `InferenceService`
/// delegates all generation operations here and preserves the unchanged
/// public API.
@Observable
@MainActor
final class GenerationQueue {

    // MARK: - Published State

    /// Whether the queue has an active generation in progress.
    ///
    /// `internal` storage, exposed as `public` via `InferenceService.isGenerating`.
    private(set) var isGenerating = false

    // MARK: - Dependencies

    /// Closure-based seam onto the owning service's backend / template state.
    ///
    /// Replaced the former `GenerationContextProvider` protocol (single in-tree
    /// conformance was `InferenceService`). Closures avoid the protocol surface
    /// entirely and match the existing pattern used to dissolve
    /// `ManifoldUI`↔`ManifoldUIModelManagement` cycles. Callers wire these
    /// after init so retain-cycle risk is on the caller (use `[weak ...]`).
    var currentBackendProvider: (@MainActor () -> (any InferenceBackend)?)?
    var isBackendLoadedProvider: (@MainActor () -> Bool)?
    var selectedPromptTemplateProvider: (@MainActor () -> PromptTemplate)?

    /// Convenience reader — returns the bound backend or `nil` when unwired.
    var currentBackend: (any InferenceBackend)? { currentBackendProvider?() }

    /// Convenience reader — returns the bound load state or `false` when unwired.
    var isBackendLoaded: Bool { isBackendLoadedProvider?() ?? false }

    /// Convenience reader — returns the bound template or `.chatML` when unwired.
    var selectedPromptTemplate: PromptTemplate { selectedPromptTemplateProvider?() ?? .chatML }

    /// Bind the backend-state closures in one call. Inverts the previous
    /// `coord.provider = self` assignment; the caller decides retain semantics
    /// via the captures it passes in.
    func bindContext(
        currentBackend: @escaping @MainActor () -> (any InferenceBackend)?,
        isBackendLoaded: @escaping @MainActor () -> Bool,
        selectedPromptTemplate: @escaping @MainActor () -> PromptTemplate
    ) {
        self.currentBackendProvider = currentBackend
        self.isBackendLoadedProvider = isBackendLoaded
        self.selectedPromptTemplateProvider = selectedPromptTemplate
    }

    /// Whether any context closures have been bound. Mirrors the old
    /// `generation.provider == nil` check the lazy-wiring path used.
    var hasBoundContext: Bool { currentBackendProvider != nil }

    /// Injected reader for the current thermal state.
    ///
    /// Defaults to `ProcessInfo.processInfo.thermalState`. Tests override this
    /// to exercise the background-priority thermal-drop branch deterministically
    /// without `@testable import` or `#if DEBUG` hooks. `@Sendable` and
    /// non-isolated so it is safe under Swift 6 strict concurrency.
    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState

    /// Sleep hook used by the per-token thermal-pause loop. Defaults to
    /// `Task.sleep(for:)`. Tests override this to skip the real 2-second
    /// re-check delay and to count how many times the loop slept.
    ///
    /// Throws `CancellationError` when the surrounding task is cancelled —
    /// the caller propagates that to abort the wait loop alongside a
    /// regular state transition.
    private let thermalSleep: @Sendable (Duration) async throws -> Void

    /// Re-check delay between thermal polls when generation is paused.
    /// Pulled out so the test seam injects only the sleep behaviour, not
    /// the cadence — keeps the production cadence in production code.
    private static let thermalRecheckInterval: Duration = .seconds(2)

    /// Optional registry used to dispatch model-emitted ``ToolCall`` events.
    ///
    /// Stored here in wave 1 so the queue's init surface is stable for
    /// downstream wiring; the actual dispatch site lands in wave 2 Agent D.
    let toolRegistry: ToolRegistry?

    /// Gate consulted before dispatching every ``ToolCall`` through
    /// ``toolRegistry``. Defaults to ``AutoApproveGate`` so hosts that have
    /// not opted into per-call approval see unchanged behaviour.
    ///
    /// The gate is invoked on the *finalized* ``ToolCall`` — streaming
    /// argument deltas are merged by the backend before the queue
    /// observes the call event. On ``ToolApprovalDecision/denied(reason:)``
    /// the queue synthesises a ``ToolResult`` with
    /// ``ToolResult/ErrorKind/permissionDenied`` and continues the stream
    /// rather than cancelling generation.
    let toolApprovalGate: any ToolApprovalGate

    /// Session-aware handoff detector hook. The runtime sets this so the
    /// dispatch loop can intercept synthetic `transfer_to_<agent>` tool
    /// calls without the queue itself learning about ``ChatSessionRecord``.
    /// The closure receives the in-flight request's `sessionID` (may be
    /// `nil` for sessionless flows) and the model-emitted ``ToolCall``;
    /// returning `.handoff(...)` triggers a ``GenerationEvent/handoffRequested(_:)``
    /// emission and short-circuits regular tool dispatch. `nil` (the
    /// default) leaves multi-agent behaviour off entirely.
    var handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?

    /// Pre-tool-use hook installed by the runtime. Receives the in-flight
    /// request's `sessionID` so adapters can route to per-session hook
    /// registries. The dispatch loop calls this before each tool call;
    /// `nil` preserves the legacy single-host surface.
    var preToolUseHook: (@Sendable (_ toolName: String, _ arguments: String, _ sessionID: UUID?) async -> PreToolUseOutcome)?

    // MARK: - Test Seam

    /// Test-only hook invoked alongside `Log.inference.warning` when
    /// `jsonMode=true` is requested on a backend whose capabilities report
    /// `supportsNativeJSONMode == false`. Receives `(backendTypeName, message)`.
    ///
    /// Production callers never set this; it exists so unit tests can verify
    /// the silent-ignore warning is emitted without standing up an OSLogStore
    /// reader. Tests must reset it in `tearDown` to avoid cross-test leakage.
    nonisolated(unsafe) static var jsonModeUnsupportedWarningHook: (@Sendable (String, String) -> Void)?

    /// Test-only hook invoked alongside `Log.inference.warning` when a request
    /// passes `tools` to a backend whose capabilities report
    /// `supportsToolCalling == false`. Receives `(backendTypeName, message)`.
    ///
    /// Mirrors `jsonModeUnsupportedWarningHook`. The motivation is the same:
    /// tools are silently dropped on incapable backends, and without a signal
    /// the model spins on "I cannot access tools" while the host wonders why
    /// its registry is never invoked. Tests must reset this in `tearDown`.
    nonisolated(unsafe) static var toolsUnsupportedWarningHook: (@Sendable (String, String) -> Void)?

    /// Test-only hook invoked alongside `Log.inference.warning` when a request
    /// passes thinking-only hints to a backend whose capabilities report
    /// `supportsThinking == false`. Receives `(backendTypeName, message)`.
    ///
    /// Unsupported thinking hints are not fatal because older callers may set
    /// a default budget globally, but they must never be silently ignored.
    /// Tests must reset this in `tearDown` to avoid cross-test leakage.
    nonisolated(unsafe) static var thinkingUnsupportedWarningHook: (@Sendable (String, String) -> Void)?

    /// Test-only hook invoked alongside `Log.inference.info` for each tool
    /// dispatch lifecycle log line (`tool_dispatch_started` /
    /// `tool_dispatch_completed`). Receives `(eventName, fields)` where
    /// `fields` mirrors the structured fields of the OSLog message.
    ///
    /// Production callers never set this; it exists so unit tests can verify
    /// the structured log output without standing up an OSLogStore reader.
    /// Tests must reset it in `tearDown` to avoid cross-test leakage.
    nonisolated(unsafe) static var toolDispatchLogHook: (@Sendable (String, [String: String]) -> Void)?

    // MARK: - Queue Types (Private)

    private struct QueuedRequest {
        let token: GenerationRequestToken
        let priority: GenerationPriority
        let sessionID: UUID?
        /// Structured conversation history. Carries thinking signatures and
        /// tool parts intact so cloud backends with structured wire formats
        /// (Anthropic) can replay them on multi-turn requests; text-only
        /// backends collapse this to `(role, content)` at their boundary.
        let messages: [StructuredMessage]
        let systemPrompt: String?
        let config: GenerationConfig
        let stream: GenerationStream
    }

    // MARK: - Queue State (Private)

    private var nextGenerationToken: GenerationRequestToken = .zero
    private var requestQueue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?
    private var activeTask: Task<Void, Never>?
    private var continuations: [GenerationRequestToken: AsyncThrowingStream<GenerationEvent, Error>.Continuation] = [:]
    private let maxQueueDepth = 8

    // MARK: - Computed

    var hasQueuedRequests: Bool { !requestQueue.isEmpty }

    var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (currentBackend as? TokenUsageProvider)?.lastUsage
    }

    // MARK: - Initializers

    nonisolated init(
        thermalStateProvider: @Sendable @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        thermalSleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        toolRegistry: ToolRegistry? = nil,
        toolApprovalGate: any ToolApprovalGate = AutoApproveGate()
    ) {
        self.thermalStateProvider = thermalStateProvider
        self.thermalSleep = thermalSleep
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
    }

    // MARK: - Generation (Non-Queued)

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. It does **not** participate
    /// in the generation queue.
    ///
    /// When the backend conforms to ``TokenCountingBackend``, an exact token count
    /// of the assembled prompt is taken before the C-level call. If the prompt
    /// exceeds `effectiveContextSize - maxOutputTokens`, the oldest non-system
    /// messages are trimmed one pair at a time and the prompt is re-assembled,
    /// up to `maxTrimAttempts` times. If the prompt still doesn't fit after
    /// trimming, ``InferenceError/contextExhausted(promptTokens:maxOutputTokens:contextSize:)``
    /// is thrown — the overflow never reaches the C layer.
    func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false
    ) throws -> GenerationStream {
        try generate(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            maxThinkingTokens: maxThinkingTokens,
            jsonMode: jsonMode
        )
    }

    /// Structured-message variant of ``generate(messages:...)``.
    ///
    /// Threads ``StructuredMessage`` (carrying ``MessagePart`` content
    /// including thinking signatures) through to the backend boundary.
    /// Backends adopting ``StructuredHistoryReceiver`` see the structured
    /// form; text-only backends keep receiving the flattened `(role,
    /// content)` shape via ``ConversationHistoryReceiver``.
    func generate(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false
    ) throws -> GenerationStream {
        guard let backend = currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        // Single pre-dispatch chokepoint for the native-JSON-mode capability
        // check. Backends without native JSON-mode support silently ignore
        // the flag and return plain text, so we warn once per request here
        // rather than in each backend. Callers can branch on
        // `backend.capabilities.supportsNativeJSONMode` programmatically to
        // suppress the warning by not setting the flag in the first place.
        if jsonMode && !backend.capabilities.supportsNativeJSONMode {
            let backendType = String(describing: type(of: backend))
            let message = "GenerationQueue: jsonMode=true requested but \(backendType) does not support native JSON mode (capabilities.supportsNativeJSONMode == false); the flag will be ignored and the response will be plain text. Check `backend.capabilities.supportsNativeJSONMode` before setting `config.jsonMode`."
            Log.inference.warning("\(message, privacy: .public)")
            Self.jsonModeUnsupportedWarningHook?(backendType, message)
        }

        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            jsonMode: jsonMode
        )
        config.maxThinkingTokens = maxThinkingTokens

        Self.warnIfThinkingUnsupported(backend: backend, config: config)

        return try dispatchToBackend(
            backend: backend,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config
        )
    }

    // MARK: - Generation (Config-preserving entry for tool-dispatch)

    /// Generates from a message history using a caller-supplied
    /// ``GenerationConfig``, preserving every field including `tools`,
    /// `toolChoice`, and `maxToolIterations`.
    ///
    /// The primary `generate(messages:...)` entry reconstructs a config from
    /// individual parameters, which drops the tool-related fields. The
    /// tool-dispatch loop in `drainQueue` uses this entry instead so the
    /// backend sees the full config authored by the caller.
    func generateWithConfig(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        try generateWithConfig(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            config: config
        )
    }

    /// Structured-message variant of ``generateWithConfig(messages:...)``.
    func generateWithConfig(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard let backend = currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        if config.jsonMode && !backend.capabilities.supportsNativeJSONMode {
            let backendType = String(describing: type(of: backend))
            let message = "GenerationQueue: jsonMode=true requested but \(backendType) does not support native JSON mode (capabilities.supportsNativeJSONMode == false); the flag will be ignored and the response will be plain text. Check `backend.capabilities.supportsNativeJSONMode` before setting `config.jsonMode`."
            Log.inference.warning("\(message, privacy: .public)")
            Self.jsonModeUnsupportedWarningHook?(backendType, message)
        }

        Self.warnIfThinkingUnsupported(backend: backend, config: config)

        return try dispatchToBackend(
            backend: backend,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config
        )
    }

    // MARK: - Backend dispatch (Private)

    private static func warnIfThinkingUnsupported(
        backend: InferenceBackend,
        config: GenerationConfig
    ) {
        guard !backend.capabilities.supportsThinking else { return }

        var requestedHints: [String] = []
        if config.maxThinkingTokens != nil {
            requestedHints.append("maxThinkingTokens")
        }
        if config.thinkingMarkers != nil {
            requestedHints.append("thinkingMarkers")
        }
        guard !requestedHints.isEmpty else { return }

        let backendType = String(describing: type(of: backend))
        let hintList = requestedHints.joined(separator: ", ")
        let message = "GenerationQueue: thinking hint(s) \(hintList) requested but \(backendType) reports capabilities.supportsThinking == false; the backend may ignore these hints. Check `backend.capabilities.supportsThinking` before setting thinking budgets or markers."
        Log.inference.warning("\(message, privacy: .public)")
        Self.thinkingUnsupportedWarningHook?(backendType, message)
    }

    /// Common dispatch path shared by ``generate(structuredMessages:...)``
    /// and ``generateWithConfig(structuredMessages:...)``.
    ///
    /// Performs the optional exact-token pre-flight + trim loop, hands the
    /// structured history to ``StructuredHistoryReceiver`` adopters,
    /// flattens to `(role, content)` for ``ConversationHistoryReceiver``
    /// adopters, and finally invokes ``InferenceBackend/generate(...)``.
    private func dispatchToBackend(
        backend: InferenceBackend,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        if GenerationHistoryInstaller.containsImages(messages), !backend.capabilities.supportsVision {
            throw InferenceError.inferenceFailure(
                "Image attachments require a backend whose capabilities.supportsVision is true. Select a vision-capable backend before sending image parts."
            )
        }
        // Exact-count pre-flight: backends that conform to TokenCountingBackend
        // expose the real tokenizer. Use it to verify the assembled prompt fits
        // inside the context window before committing to the C-level decode.
        // The heuristic guard inside LlamaBackend.generate() remains as a
        // fast-path sanity check for obviously-too-large prompts, but this
        // trim-and-retry loop is the definitive gate that prevents KV overflow.
        if let counter = backend as? TokenCountingBackend,
           backend.capabilities.requiresPromptTemplate {
            let result = try GenerationPreflightTrimmer(
                promptTemplate: selectedPromptTemplate
            ).exactPreflightAndTrim(
                counter: counter,
                backend: backend,
                messages: messages,
                systemPrompt: systemPrompt,
                config: config
            )
            GenerationHistoryInstaller.installHistory(on: backend, structuredMessages: result.trimmedMessages)
            return try backend.generate(
                prompt: result.prompt,
                systemPrompt: nil,
                config: config
            )
        }

        // Non-TokenCountingBackend path: assemble prompt and forward.
        // For backends that require a prompt template, messages are formatted
        // into a single string. Otherwise the most recent user message is
        // passed directly and the system prompt goes through a separate channel.
        let flattened = GenerationHistoryInstaller.flatten(messages)
        let assembledPrompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            let template = selectedPromptTemplate
            if backend.capabilities.supportsToolCalling && !config.tools.isEmpty {
                assembledPrompt = template.format(messages: flattened, systemPrompt: systemPrompt, tools: config.tools)
            } else {
                assembledPrompt = template.format(messages: flattened, systemPrompt: systemPrompt)
            }
            effectiveSystemPrompt = nil
        } else {
            assembledPrompt = flattened.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        GenerationHistoryInstaller.installHistory(on: backend, structuredMessages: messages)

        return try backend.generate(
            prompt: assembledPrompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    // MARK: - Generation Queue

    /// The single value-typed enqueue entry point.
    ///
    /// Takes a pre-built ``GenerationConfig`` plus the small non-config triple
    /// (`priority`, `sessionID`, and the structured `messages`/`systemPrompt`).
    /// Every parameterized convenience overload funnels here after assembling a
    /// config, so the capability gates, queue-depth check, token/stream
    /// construction, and FIFO+priority insertion live in exactly one place.
    func enqueue(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        config: GenerationConfig,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        guard let backend = currentBackend, isBackendLoaded else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard requestQueue.count < maxQueueDepth else {
            throw InferenceError.inferenceFailure("Generation queue is full")
        }

        // Capability gate for tool calling. A backend that reports
        // `supportsToolCalling == false` has no wire path for tool definitions
        // — they are silently dropped, and the model loops on "I cannot access
        // tools" while the host's registry never sees the call. Reject the
        // request up front with a clear error so the failure is diagnosable
        // at the call site rather than manifesting as a silent no-op.
        if !config.tools.isEmpty && !backend.capabilities.supportsToolCalling {
            let backendType = String(describing: type(of: backend))
            let toolWord = config.tools.count == 1 ? "tool" : "tools"
            let message = "GenerationQueue: \(config.tools.count) \(toolWord) passed to enqueue() but \(backendType) reports capabilities.supportsToolCalling == false; tools will be ignored on the wire and tool calls will never be dispatched. Check `backend.capabilities.supportsToolCalling` before passing tools, or load a tool-capable backend."
            Log.inference.warning("\(message, privacy: .public)")
            Self.toolsUnsupportedWarningHook?(backendType, message)
            throw InferenceError.inferenceFailure("Tools passed to a backend that does not support tool calling (\(backendType)); set capabilities.supportsToolCalling = true or remove tools from the request.")
        }

        let token = GenerationRequestToken(rawValue: nextGenerationToken.rawValue + 1)
        nextGenerationToken = token

        var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation!
        let rawStream = AsyncThrowingStream<GenerationEvent, Error> { continuation = $0 }
        let stream = GenerationStream(rawStream)
        stream.setPhase(.queued)
        continuations[token] = continuation

        Self.warnIfThinkingUnsupported(backend: backend, config: config)

        let request = QueuedRequest(
            token: token,
            priority: priority,
            sessionID: sessionID,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            stream: stream
        )

        if let insertIdx = requestQueue.firstIndex(where: { $0.priority < priority }) {
            requestQueue.insert(request, at: insertIdx)
        } else {
            requestQueue.append(request)
        }

        drainQueue()
        return (token: token, stream: stream)
    }

    /// Assembles a ``GenerationConfig`` from the individual sampling parameters
    /// in the exact shape the parameterized `enqueue` overloads have always
    /// produced. Centralised so both the tuple and structured builders match
    /// field-for-field.
    static func makeEnqueueConfig(
        temperature: Float,
        topP: Float,
        repeatPenalty: Float,
        topK: Int32?,
        minP: Float?,
        presencePenalty: Float?,
        frequencyPenalty: Float?,
        seed: UInt64?,
        maxOutputTokens: Int?,
        maxThinkingTokens: Int?,
        jsonMode: Bool,
        grammar: String?,
        tools: [ToolDefinition],
        toolChoice: ToolChoice,
        maxToolIterations: Int
    ) -> GenerationConfig {
        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            topK: topK,
            minP: minP,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            tools: tools,
            toolChoice: toolChoice,
            jsonMode: jsonMode,
            maxToolIterations: maxToolIterations
        )
        config.maxThinkingTokens = maxThinkingTokens
        config.grammar = grammar
        return config
    }

    func enqueue(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        topK: Int32? = nil,
        minP: Float? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        seed: UInt64? = nil,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        grammar: String? = nil,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxToolIterations: Int = 10,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        try enqueue(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            config: Self.makeEnqueueConfig(
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                topK: topK,
                minP: minP,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                jsonMode: jsonMode,
                grammar: grammar,
                tools: tools,
                toolChoice: toolChoice,
                maxToolIterations: maxToolIterations
            ),
            priority: priority,
            sessionID: sessionID
        )
    }

    /// Structured-message variant of ``enqueue(messages:...)``.
    ///
    /// Threads ``StructuredMessage`` (with thinking signatures and tool
    /// parts intact) through the queue to the backend boundary. This is the
    /// entry point used by ChatViewModel so prior-turn thinking blocks can
    /// be replayed verbatim against APIs that require them (Anthropic).
    func enqueue(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        topK: Int32? = nil,
        minP: Float? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        seed: UInt64? = nil,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        grammar: String? = nil,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxToolIterations: Int = 10,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        try enqueue(
            structuredMessages: messages,
            systemPrompt: systemPrompt,
            config: Self.makeEnqueueConfig(
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                topK: topK,
                minP: minP,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                jsonMode: jsonMode,
                grammar: grammar,
                tools: tools,
                toolChoice: toolChoice,
                maxToolIterations: maxToolIterations
            ),
            priority: priority,
            sessionID: sessionID
        )
    }

    /// Processes the next queued request if no generation is active.
    private func drainQueue() {
        guard activeRequest == nil, !requestQueue.isEmpty else { return }

        let next = requestQueue.removeFirst()

        // Thermal gate: drop background requests under thermal pressure.
        if next.priority == .background {
            let thermal = thermalStateProvider()
            if thermal == .serious || thermal == .critical {
                let throttleError = InferenceError.inferenceFailure("Thermal throttle")
                Log.inference.warning("Dropping background generation \(next.token): thermal state \(thermal.rawValue)")
                next.stream.setPhase(.failed(throttleError.localizedDescription))
                finishAndDiscard(next.token, error: throttleError)
                drainQueue()
                return
            }
        }

        activeRequest = next
        isGenerating = true
        next.stream.setPhase(.connecting)

        activeTask = Task { [weak self] in
            guard let self else { return }

            var thrownError: Error?
            defer {
                if let continuation = self.continuations.removeValue(forKey: next.token) {
                    if let thrownError {
                        continuation.finish(throwing: thrownError)
                    } else if Task.isCancelled {
                        // Cancellation contract: when the surrounding task
                        // was cancelled (by `stopGeneration()`/`cancel(_:)`),
                        // finish the stream by throwing `CancellationError`
                        // so consumers' `for try await` loops surface the
                        // cancellation. Tool-dispatch may have already
                        // yielded a `.toolResult(.cancelled)` event into
                        // this same continuation; that event is preserved
                        // because the throwing-finish only fires after the
                        // earlier yields land in the stream buffer.
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish()
                    }
                }
                if self.activeRequest?.token == next.token {
                    self.activeRequest = nil
                    self.activeTask = nil
                    self.isGenerating = false
                    self.drainQueue()
                }
            }

            do {
                try await self.runToolDispatchLoop(request: next)

                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.done)
                }
            } catch {
                thrownError = error
                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Thermal pause

    /// Cooperatively pauses the per-token loop while the device is in
    /// `.critical` thermal state. Returns immediately when thermal state is
    /// `.serious` or below, or when the surrounding task has been cancelled.
    ///
    /// Emits `GenerationEvent.diagnosticThrottle` exactly once per pause
    /// cycle — on entry, before the first sleep — so UI surfaces can show
    /// "device throttling — paused" without being spammed every re-check.
    /// Generation resumes silently when thermal pressure drops; downstream
    /// `.token` events resuming after the pause is the implicit "resumed"
    /// signal.
    private func pauseWhileThermalCritical(
        token: GenerationRequestToken
    ) async {
        guard thermalStateProvider() == .critical else { return }

        // Entry-only event: spamming the continuation on every re-check would
        // bloat the stream and make UI debouncing harder. The event is fired
        // once and the consumer keeps showing the throttle hint until the
        // next regular event flows through.
        self.continuations[token]?.yield(
            .diagnosticThrottle(reason: "thermalState=.critical")
        )
        Log.inference.warning(
            "GenerationQueue: pausing generation — ProcessInfo.thermalState == .critical"
        )

        while !Task.isCancelled {
            do {
                try await thermalSleep(Self.thermalRecheckInterval)
            } catch {
                // Sleep was cancelled — propagate by exiting the loop. The
                // outer `for try await event in stream.events` will observe
                // `Task.isCancelled` on its next iteration.
                return
            }
            if thermalStateProvider() != .critical {
                Log.inference.info(
                    "GenerationQueue: thermal state dropped below .critical — resuming generation"
                )
                return
            }
        }
    }

    // MARK: - Tool Dispatch Loop

    /// Drives the backend through an entire tool-dispatch loop for one queued request.
    private func runToolDispatchLoop(request: QueuedRequest) async throws {
        // Bind the per-request hook closures explicitly so the type checker
        // doesn't have to infer them inside the giant init expression below.
        let boundPreToolUseHook: PreToolUseHook? = preToolUseHook.map { hook in
            let sessionID = request.sessionID
            return { @Sendable toolName, arguments, _ in
                await hook(toolName, arguments, sessionID)
            }
        }
        let loop = GenerationToolDispatchLoop(
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate,
            currentBackend: { [weak self] in self?.currentBackend },
            generateWithConfig: { [weak self] messages, systemPrompt, config in
                guard let self else {
                    throw InferenceError.inferenceFailure("Generation queue deallocated")
                }
                return try self.generateWithConfig(
                    structuredMessages: messages,
                    systemPrompt: systemPrompt,
                    config: config
                )
            },
            yieldEvent: { [weak self] event in
                self?.continuations[request.token]?.yield(event)
                if case .token = event, request.stream.phase != .streaming {
                    request.stream.setPhase(.streaming)
                }
            },
            pauseWhileThermalCritical: { [weak self] token in
                await self?.pauseWhileThermalCritical(token: token)
            },
            handoffDetector: handoffDetector.map { detector in
                { [sessionID = request.sessionID] call in
                    detector(sessionID, call)
                }
            },
            preToolUseHook: boundPreToolUseHook
        )

        try await loop.run(
            token: request.token,
            messages: request.messages,
            systemPrompt: request.systemPrompt,
            config: request.config
        )
    }

    private func finishAndDiscard(_ token: GenerationRequestToken, error: Error? = nil) {
        if let error {
            continuations[token]?.finish(throwing: error)
        } else {
            continuations[token]?.finish(throwing: CancellationError())
        }
        continuations.removeValue(forKey: token)
    }

    func cancel(_ token: GenerationRequestToken) {
        if activeRequest?.token == token {
            currentBackend?.stopGeneration()
            activeTask?.cancel()
            activeTask = nil
            activeRequest?.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
            activeRequest = nil
            isGenerating = false
            drainQueue()
        } else if let idx = requestQueue.firstIndex(where: { $0.token == token }) {
            let req = requestQueue.remove(at: idx)
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
        }
    }

    func discardRequests(notMatching sessionID: UUID) async {
        requestQueue.removeAll { req in
            guard let reqSession = req.sessionID, reqSession != sessionID else { return false }
            req.stream.setPhase(.failed("Session changed"))
            finishAndDiscard(req.token, error: InferenceError.inferenceFailure("Session changed"))
            return true
        }
        if let active = activeRequest,
           let activeSession = active.sessionID,
           activeSession != sessionID {
            // Capture the active task handle before `cancel` clears it. The
            // task's `defer` block in `drainQueue` clears `activeRequest`,
            // releases `isGenerating`, and finishes the continuation; if the
            // caller (a session switch) re-enqueues before that defer runs,
            // the new request can land on a queue mid-tear-down (issue #965).
            // Awaiting the task's value here serialises the next enqueue
            // behind the dying turn so B's send sees a clean slot.
            let dyingTask = activeTask
            cancel(active.token)
            await dyingTask?.value
        }
    }

    func stopGeneration() {
        currentBackend?.stopGeneration()
        activeTask?.cancel()
        activeTask = nil
        // Don't call `finishAndDiscard` on the active request here: doing
        // so would close the continuation immediately, racing past any
        // in-flight tool dispatch that's about to emit a
        // `.toolResult(.cancelled)` event into the transcript (issue #622).
        // The cancelled task's `defer` block in ``drainQueue`` finishes
        // the continuation cleanly once the task unwinds — that's the path
        // we want for the active request. Clearing `activeRequest` here
        // ensures a fresh enqueue right after stop is not queued behind
        // the dying task; the late-defer's
        // `if self.activeRequest?.token == next.token` guard skips the
        // redundant reset because the slot has already been cleared.
        if let active = activeRequest {
            active.stream.setPhase(.failed("Cancelled"))
        }
        activeRequest = nil
        isGenerating = false

        for req in requestQueue {
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(req.token, error: CancellationError())
        }
        requestQueue.removeAll()
    }

    /// Cancels active generation and awaits the task's completion before returning.
    ///
    /// Captures the active task handle before calling `stopGeneration()` so the
    /// task's defer block fully completes before the caller proceeds.
    func stopGenerationAndWait() async {
        let task = activeTask
        stopGeneration()
        await task?.value
    }

}
