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

    weak var provider: (any GenerationContextProvider)?

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
        (provider?.currentBackend as? TokenUsageProvider)?.lastUsage
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
        guard let backend = provider?.currentBackend else {
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
        guard let backend = provider?.currentBackend else {
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
        if Self.containsImages(messages), !backend.capabilities.supportsVision {
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
            let result = try exactPreflightAndTrim(
                counter: counter,
                backend: backend,
                messages: messages,
                systemPrompt: systemPrompt,
                config: config
            )
            installHistory(on: backend, structuredMessages: result.trimmedMessages)
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
        let flattened = flatten(messages)
        let assembledPrompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            let template = provider?.selectedPromptTemplate ?? .chatML
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

        installHistory(on: backend, structuredMessages: messages)

        return try backend.generate(
            prompt: assembledPrompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    /// Flattens ``StructuredMessage`` to the legacy `(role, content)` shape
    /// for backends and helpers that operate on plain strings (prompt
    /// templates, ``ConversationHistoryReceiver``).
    ///
    /// Thinking parts are dropped because they would either bloat the prompt
    /// with provider-internal reasoning or fail validation on the
    /// non-Anthropic providers that don't accept replayed thinking.
    /// ``StructuredHistoryReceiver`` adopters read the unflattened form
    /// directly to preserve thinking signatures.
    private static func flatten(_ messages: [StructuredMessage]) -> [(role: String, content: String)] {
        messages.map { (role: $0.role, content: $0.textContent) }
    }

    /// Instance-level wrapper around the static flatten so call sites stay readable.
    private func flatten(_ messages: [StructuredMessage]) -> [(role: String, content: String)] {
        Self.flatten(messages)
    }

    private static func containsImages(_ messages: [StructuredMessage]) -> Bool {
        messages.contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }
    }

    /// Hands history to whichever receiver protocol the backend conforms to.
    ///
    /// A backend may conform to both — ``StructuredHistoryReceiver`` is set
    /// first so a backend that needs structured access (Anthropic) gets the
    /// authoritative shape, and the flattened ``ConversationHistoryReceiver``
    /// fallback is set afterwards for backends that only inspect strings.
    private func installHistory(on backend: InferenceBackend, structuredMessages: [StructuredMessage]) {
        if let structuredReceiver = backend as? StructuredHistoryReceiver {
            structuredReceiver.setStructuredHistory(structuredMessages)
        }
        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(flatten(structuredMessages))
        }
    }

    // MARK: - Exact Pre-flight (Private)

    private struct ExactPreflightResult {
        let prompt: String
        let trimmedMessages: [StructuredMessage]
    }

    /// Counts tokens on the assembled prompt and trims the oldest non-system
    /// messages until the prompt fits inside the context window.
    ///
    /// Up to `maxTrimAttempts` trimming rounds are performed. Each round drops
    /// one non-system message from the front of the history. If the budget is
    /// still exceeded after all attempts, throws
    /// ``InferenceError/contextExhausted(promptTokens:maxOutputTokens:contextSize:)``.
    private func exactPreflightAndTrim(
        counter: TokenCountingBackend,
        backend: InferenceBackend,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig,
        maxTrimAttempts: Int = 20
    ) throws -> ExactPreflightResult {
        let contextSize = Int(backend.capabilities.maxContextTokens)
        // Reserve context for both visible output and (optionally) thinking output.
        //
        // Rationale for `?? 0` on the thinking side (not `?? 2048`): the public
        // semantics of `maxThinkingTokens` today are "cap reasoning output; nil
        // means no client-side cap." Reserving a fixed slice of the context
        // window for thinking by default would silently eat that many tokens
        // from every prompt — including on non-thinking models where it has no
        // effect on runtime behaviour. Principle of least surprise: only
        // reserve what the caller explicitly asked for. Callers who know they
        // are driving a reasoning model can opt in by setting
        // `maxThinkingTokens: N`, which then becomes the trim reservation.
        let visibleReserve = config.maxOutputTokens ?? 2048
        let thinkingReserve = config.maxThinkingTokens ?? 0
        let maxOutput = visibleReserve + thinkingReserve
        let template = provider?.selectedPromptTemplate ?? .chatML

        var workingMessages = messages
        var attempt = 0

        while true {
            let prompt = template.format(messages: Self.flatten(workingMessages), systemPrompt: systemPrompt)
            let promptTokens = try counter.countTokens(prompt)

            if promptTokens + maxOutput <= contextSize {
                // Fits — return the (possibly trimmed) result.
                return ExactPreflightResult(prompt: prompt, trimmedMessages: workingMessages)
            }

            // Over budget. If we've used all trim rounds, surface the error before
            // anything reaches the C layer.
            guard attempt < maxTrimAttempts else {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            // Find the oldest non-system message to drop. System messages are
            // passed in the `systemPrompt` parameter, not as tuples, so any
            // "system"-role tuple here is a slot injected by PromptAssembler.
            // We trim those too — keeping only the final user turn is better
            // than overflowing the KV cache.
            guard let dropIndex = workingMessages.firstIndex(where: { $0.role != "system" }) else {
                // Only system messages remain — nothing left to trim.
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            // Always protect the last user message: if dropping it would leave
            // no user turn, stop trimming and surface the error.
            let userCount = workingMessages.filter { $0.role == "user" }.count
            if userCount <= 1 && workingMessages[dropIndex].role == "user" {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            Log.inference.warning(
                "GenerationQueue: prompt over budget — trimming oldest non-system message (attempt \(attempt + 1)/\(maxTrimAttempts))"
            )
            workingMessages.remove(at: dropIndex)
            attempt += 1
        }
    }

    // MARK: - Generation Queue

    func enqueue(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
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
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            maxThinkingTokens: maxThinkingTokens,
            jsonMode: jsonMode,
            grammar: grammar,
            tools: tools,
            toolChoice: toolChoice,
            maxToolIterations: maxToolIterations,
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
        guard let backend = provider?.currentBackend, provider?.isBackendLoaded == true else {
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
        if !tools.isEmpty && !backend.capabilities.supportsToolCalling {
            let backendType = String(describing: type(of: backend))
            let toolWord = tools.count == 1 ? "tool" : "tools"
            let message = "GenerationQueue: \(tools.count) \(toolWord) passed to enqueue() but \(backendType) reports capabilities.supportsToolCalling == false; tools will be ignored on the wire and tool calls will never be dispatched. Check `backend.capabilities.supportsToolCalling` before passing tools, or load a tool-capable backend."
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

        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            tools: tools,
            toolChoice: toolChoice,
            jsonMode: jsonMode,
            maxToolIterations: maxToolIterations
        )
        config.maxThinkingTokens = maxThinkingTokens
        config.grammar = grammar

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

    /// Upper bound on cumulative bytes of tool-result content that can be
    /// fed back into a single generation request.
    ///
    /// Tool results flow directly into the next-turn prompt, so a runaway
    /// tool (imagine one that mirrors an entire wiki article) can exhaust
    /// the KV cache on the server side just as surely as a misbehaving
    /// prompt. 512 KiB is deliberately generous for typical tool output
    /// (seconds-of-weather JSON, search snippets) but still well under the
    /// memory floor that would put an Ollama / local-llama deployment at
    /// risk. Overflow short-circuits the loop with a `.permanent`
    /// synthetic result rather than running another turn.
    private static let toolResultByteBudget: Int = 512 * 1024

    /// Drives the backend through an entire tool-dispatch loop for one
    /// queued request.
    ///
    /// On each iteration the backend is invoked with the current message
    /// history (original + any tool-call / tool-result entries accumulated
    /// from prior iterations). Events flow through to the request's
    /// continuation untouched *except* for `.toolCall(_:)` events, which
    /// are intercepted when a registry is present:
    ///
    /// 1. The finalized ``ToolCall`` is passed to ``toolApprovalGate``. On
    ///    ``ToolApprovalDecision/approved`` the call is dispatched via
    ///    `toolRegistry.dispatch(_:)`; on ``ToolApprovalDecision/denied(reason:)``
    ///    a synthetic ``ToolResult`` with
    ///    ``ToolResult/ErrorKind/permissionDenied`` is produced in place of
    ///    a real dispatch, and the loop continues to the next turn so the
    ///    model can acknowledge the refusal.
    /// 2. A `.toolResult(_:)` event is emitted so UIs can render the
    ///    outcome alongside the call.
    /// 3. The `(call, result)` pair is appended to the tool-aware history
    ///    for the next iteration.
    ///
    /// Termination conditions:
    /// - The backend's stream finishes without emitting any new tool call
    ///   → normal completion.
    /// - `config.maxToolIterations` reached → emit `.toolLoopLimitReached`
    ///   and stop.
    /// - Cumulative tool-result bytes exceed ``toolResultByteBudget`` →
    ///   synthesise a `.permanent` error result and stop.
    /// - Backend emits an identical `(toolName, arguments)` pair twice in
    ///   a row → short-circuit the executor and feed a synthetic
    ///   "already-called-with-identical-args" result back so the model
    ///   can recover without another identical round trip.
    private func runToolDispatchLoop(request: QueuedRequest) async throws {
        // First-time-only wiring: make sure the registry has a schema
        // validator installed so tools with non-trivial parameter schemas
        // get argument validation without requiring the host to know about
        // the `JSONSchemaValidating` protocol.
        if let registry = toolRegistry, registry.validator == nil {
            registry.validator = JSONSchemaValidator()
        }

        let currentMessages = request.messages
        // `toolAwareHistory` is maintained in parallel for tool-call turns.
        // Seeded lazily on the first tool dispatch so plain-text turns keep
        // using the classic `setConversationHistory` path and existing
        // backends that don't know about tool-aware history see no change.
        var toolAwareHistory: [ToolAwareHistoryEntry]?
        var lastCallSignature: (toolName: String, arguments: String)?
        var toolResultByteTotal = 0
        var iterations = 0
        let limit = max(1, request.config.maxToolIterations)

        while true {
            iterations += 1
            if iterations > limit {
                // Cap reached — loop terminated before invoking the backend
                // with the next turn's request.
                Log.inference.warning(
                    "GenerationQueue: tool-dispatch loop hit maxToolIterations=\(limit, privacy: .public); terminating."
                )
                self.continuations[request.token]?.yield(
                    .toolLoopLimitReached(iterations: limit)
                )
                return
            }

            // Feed the tool-aware history to the backend when one is
            // available. Non-tool backends ignore the cast and fall back to
            // the plain conversation history via `generateWithConfig`.
            if let toolAwareHistory,
               let receiver = provider?.currentBackend as? ToolCallingHistoryReceiver {
                receiver.setToolAwareHistory(toolAwareHistory)
            }

            let stream = try self.generateWithConfig(
                structuredMessages: currentMessages,
                systemPrompt: request.systemPrompt,
                config: request.config
            )

            var dispatchedInThisTurn: [(ToolCall, ToolResult)] = []

            for try await event in stream.events {
                guard !Task.isCancelled else { return }

                // Thermal gate (cooperative): if the device is in `.critical`
                // thermal state, pause between tokens until pressure drops to
                // `.serious` or below, or until the surrounding task is
                // cancelled. This is a no-op on the hot path — one provider
                // read per event when temperature is fine.
                await pauseWhileThermalCritical(token: request.token)
                guard !Task.isCancelled else { return }

                if case .token = event, request.stream.phase != .streaming {
                    request.stream.setPhase(.streaming)
                }

                switch event {
                case .toolCall(let call) where toolRegistry != nil:
                    // Forward the call event so UI surfaces can render it
                    // alongside the pending result.
                    self.continuations[request.token]?.yield(.toolCall(call))

                    // Lifecycle: announce dispatch start so UI surfaces can
                    // start a per-call timer / spinner without scraping the
                    // log. `attempt` is reserved for future retry semantics
                    // and pinned to 1 today (no per-call retry path exists).
                    let dispatchAttempt = 1
                    // Monotonic clock so `durationMs` reflects actual elapsed
                    // time even when wall-clock jumps (NTP / user time-zone
                    // change) happen mid-dispatch.
                    let dispatchStart = DispatchTime.now()
                    self.continuations[request.token]?.yield(
                        .toolDispatchStarted(callId: call.id, name: call.toolName, attempt: dispatchAttempt)
                    )
                    Log.inference.info(
                        "tool_dispatch_started call_id=\(call.id, privacy: .public) name=\(call.toolName, privacy: .public) attempt=\(dispatchAttempt, privacy: .public)"
                    )
                    Self.toolDispatchLogHook?(
                        "tool_dispatch_started",
                        [
                            "call_id": call.id,
                            "name": call.toolName,
                            "attempt": "\(dispatchAttempt)"
                        ]
                    )

                    let result: ToolResult
                    if let prev = lastCallSignature,
                       prev.toolName == call.toolName,
                       prev.arguments == call.arguments {
                        // Identical repeat — don't re-invoke the executor.
                        Log.inference.warning(
                            "GenerationQueue: tool '\(call.toolName, privacy: .public)' called twice in a row with identical arguments; short-circuiting to previous result."
                        )
                        let prevContent = dispatchedInThisTurn.last?.1.content ?? ""
                        result = ToolResult(
                            callId: call.id,
                            content: "tool already called this turn with identical arguments — previous result was: \(prevContent)",
                            errorKind: .permanent
                        )
                    } else if toolResultByteTotal >= Self.toolResultByteBudget {
                        Log.inference.warning(
                            "GenerationQueue: tool-result byte budget (\(Self.toolResultByteBudget, privacy: .public)) exhausted before dispatching '\(call.toolName, privacy: .public)'; terminating loop."
                        )
                        result = ToolResult(
                            callId: call.id,
                            content: "tool result budget exhausted",
                            errorKind: .permanent
                        )
                    } else if toolRegistry!.requiresApproval(toolName: call.toolName) == false {
                        // Read-only / safe tool — skip the gate hop entirely so
                        // pure-read scenarios don't flash an approval sheet.
                        // Side-effecting tools opt in via
                        // ``ToolExecutor/requiresApproval``.
                        //
                        // Cancellation contract (issue #622): the registry
                        // dispatch runs under structured concurrency on the
                        // orchestrator's `activeTask`, so a `Task.cancel()`
                        // from `stopGeneration()` flows straight into the
                        // executor. Cancellation-aware executors observe
                        // `Task.isCancelled` / throw `CancellationError`;
                        // ``ToolRegistry/dispatch(_:)`` classifies that as
                        // ``ToolResult/ErrorKind/cancelled``, which the
                        // post-dispatch guard below uses to exit the loop
                        // without running another backend turn.
                        result = await toolRegistry!.dispatch(call)
                    } else {
                        // User-approval gate: invoked on the finalized ToolCall,
                        // after the repeat / byte-budget guards (which both
                        // synthesize their own results without touching the
                        // registry). On `.denied` we emit a `.permissionDenied`
                        // ToolResult and continue the loop — the backend sees a
                        // structured refusal and the model usually apologises
                        // and asks what to do next.
                        switch await toolApprovalGate.approve(call) {
                        case .approved:
                            result = await toolRegistry!.dispatch(call)
                        case .denied(let reason):
                            Log.inference.info(
                                "GenerationQueue: tool '\(call.toolName, privacy: .public)' denied by ToolApprovalGate"
                            )
                            result = ToolResult(
                                callId: call.id,
                                content: reason ?? "user denied tool execution",
                                errorKind: .permissionDenied
                            )
                        }
                    }

                    toolResultByteTotal += result.content.utf8.count
                    lastCallSignature = (toolName: call.toolName, arguments: call.arguments)
                    dispatchedInThisTurn.append((call, result))

                    // Emit the result so the UI can render it; downstream
                    // consumers thread `.toolResult` into the current
                    // assistant bubble before the next turn begins.
                    self.continuations[request.token]?.yield(.toolResult(result))

                    // Lifecycle: announce dispatch completion. Fires after
                    // `.toolResult` so consumers that switch on the lifecycle
                    // pair see exactly one `.toolDispatchStarted` →
                    // `.toolDispatchCompleted` per call. `errorKind` mirrors
                    // the result's classification (nil on success).
                    let dispatchDurationNs = DispatchTime.now().uptimeNanoseconds &- dispatchStart.uptimeNanoseconds
                    let dispatchDurationMs = Int(dispatchDurationNs / 1_000_000)
                    self.continuations[request.token]?.yield(
                        .toolDispatchCompleted(
                            callId: call.id,
                            durationMs: dispatchDurationMs,
                            errorKind: result.errorKind
                        )
                    )
                    Log.inference.info(
                        "tool_dispatch_completed call_id=\(call.id, privacy: .public) duration_ms=\(dispatchDurationMs, privacy: .public) error_kind=\(result.errorKind?.rawValue ?? "none", privacy: .public)"
                    )
                    Self.toolDispatchLogHook?(
                        "tool_dispatch_completed",
                        [
                            "call_id": call.id,
                            "duration_ms": "\(dispatchDurationMs)",
                            "error_kind": result.errorKind?.rawValue ?? "none"
                        ]
                    )

                    // Cancellation contract (issue #622): when the user hits
                    // stop while a tool is in flight the dispatch path returns
                    // a ``ToolResult/ErrorKind/cancelled`` synthesized by
                    // ``ToolRegistry/dispatch(_:)``. The transcript-side yield
                    // above records it; here we stop the loop cleanly so no
                    // further backend turn runs against the now-cancelled
                    // task.
                    if result.errorKind == .cancelled {
                        return
                    }

                    // Overflow after this dispatch — synthesise a terminal
                    // marker and exit before running another turn.
                    if toolResultByteTotal >= Self.toolResultByteBudget {
                        return
                    }

                default:
                    self.continuations[request.token]?.yield(event)
                }
            }

            // If no tool calls were dispatched this turn, generation is
            // complete.
            if dispatchedInThisTurn.isEmpty {
                return
            }

            // Otherwise augment the tool-aware history with the tool-call +
            // tool-result pairs the model produced this turn, then loop.
            var nextHistory = toolAwareHistory ?? currentMessages.map {
                ToolAwareHistoryEntry(role: $0.role, content: $0.textContent)
            }
            nextHistory.append(
                ToolAwareHistoryEntry(
                    role: "assistant",
                    content: "",
                    toolCalls: dispatchedInThisTurn.map(\.0)
                )
            )
            for (call, result) in dispatchedInThisTurn {
                nextHistory.append(
                    ToolAwareHistoryEntry(
                        role: "tool",
                        content: result.content,
                        toolCallId: call.id
                    )
                )
            }
            toolAwareHistory = nextHistory
            // Keep `currentMessages` in sync so backends without
            // tool-aware support at least see the user-side history.
            // Tool/assistant-tool-call entries are omitted from the plain
            // path because `(role, content)` can't carry call ids faithfully.
        }
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
            provider?.currentBackend?.stopGeneration()
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
        provider?.currentBackend?.stopGeneration()
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
