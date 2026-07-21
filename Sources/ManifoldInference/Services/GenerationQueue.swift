import Foundation
import Observation
import os

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

    /// Reader onto the active model's embedded Jinja chat-template string, or
    /// `nil` for templateless models. When present and renderable it drives the
    /// prompt via the model's *real* template (#1811); otherwise the enum from
    /// ``selectedPromptTemplateProvider`` is used. Bound after init alongside the
    /// other context closures; an unbound provider means "no embedded template",
    /// which preserves the pre-#1811 enum-only behaviour.
    var selectedChatTemplateRawProvider: (@MainActor () -> String?)?

    /// Convenience reader — returns the bound backend or `nil` when unwired.
    var currentBackend: (any InferenceBackend)? { currentBackendProvider?() }

    /// Convenience reader — returns the bound load state or `false` when unwired.
    var isBackendLoaded: Bool { isBackendLoadedProvider?() ?? false }

    /// Convenience reader — returns the bound template or `.chatML` when unwired.
    var selectedPromptTemplate: PromptTemplate { selectedPromptTemplateProvider?() ?? .chatML }

    /// Convenience reader — returns the bound embedded template, or `nil`.
    var selectedChatTemplateRaw: String? { selectedChatTemplateRawProvider?() }

    /// The renderer for the active model: prefers the real embedded Jinja
    /// template, falls back to the detected enum (#1811).
    var promptRenderer: PromptRenderer {
        PromptRenderer(template: selectedPromptTemplate, chatTemplateRaw: selectedChatTemplateRaw)
    }

    /// The typed ``ChatTemplate`` for the active model (#1944). Used to derive
    /// template-default stop sequences. Mirrors ``promptRenderer``'s
    /// embedded-vs-enum precedence: an embedded Jinja string wins.
    var chatTemplate: ChatTemplate {
        if let raw = selectedChatTemplateRaw,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ChatTemplate(embeddedJinja: raw)
        }
        return ChatTemplate(builtIn: selectedPromptTemplate)
    }

    /// Returns `config` with its ``GenerationConfig/stopSequences`` filled from
    /// the active template's defaults when the caller did not set any (#1944).
    ///
    /// Merge policy: a caller-supplied list wins outright (caller overrides);
    /// an empty list inherits the template-derived turn-terminators. In-core
    /// backends may ignore stop sequences (like `seed`); companion backends read
    /// them to cut generation at the turn boundary.
    func applyingTemplateStopSequences(to config: GenerationConfig) -> GenerationConfig {
        guard config.stopSequences.isEmpty else { return config }
        let derived = chatTemplate.stopSequences
        guard !derived.isEmpty else { return config }
        var merged = config
        merged.stopSequences = derived
        return merged
    }

    /// Bind the backend-state closures in one call. Inverts the previous
    /// `coord.provider = self` assignment; the caller decides retain semantics
    /// via the captures it passes in.
    func bindContext(
        currentBackend: @escaping @MainActor () -> (any InferenceBackend)?,
        isBackendLoaded: @escaping @MainActor () -> Bool,
        selectedPromptTemplate: @escaping @MainActor () -> PromptTemplate,
        selectedChatTemplateRaw: (@MainActor () -> String?)? = nil
    ) {
        self.currentBackendProvider = currentBackend
        self.isBackendLoadedProvider = isBackendLoaded
        self.selectedPromptTemplateProvider = selectedPromptTemplate
        self.selectedChatTemplateRawProvider = selectedChatTemplateRaw
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
    /// calls without the queue itself learning about ``ChatSession``.
    /// The closure receives the in-flight request's `requestGroupID` (may be
    /// `nil` for sessionless flows) and the model-emitted ``ToolCall``;
    /// returning `.handoff(...)` triggers a ``GenerationEvent/handoffRequested(_:)``
    /// emission and short-circuits regular tool dispatch. `nil` (the
    /// default) leaves multi-agent behaviour off entirely.
    var handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?

    /// Pre-tool-use hook installed by the runtime. Receives the in-flight
    /// request's `requestGroupID` so adapters can route to per-session hook
    /// registries. The dispatch loop calls this before each tool call;
    /// `nil` preserves the legacy single-host surface.
    var preToolUseHook: (@Sendable (_ toolName: String, _ arguments: String, _ requestGroupID: UUID?) async -> PreToolUseOutcome)?

    // MARK: - Test Seam

    /// Lock-guarded backing storage for the four test-injection hooks below.
    /// The previous bare `nonisolated(unsafe) static var`s raced when real
    /// generation warned/logged on one thread while a test set/reset a hook
    /// from another (issue #2094). Mirrors `CloudImageEncoding._encodeHook`,
    /// which fixed the identical class of bug for this same
    /// `toolDispatchLogHook` — that fix was never backported here until now.
    nonisolated private static let _jsonModeUnsupportedWarningHookStorage =
        OSAllocatedUnfairLock<(@Sendable (String, String) -> Void)?>(initialState: nil)
    nonisolated private static let _toolsUnsupportedWarningHookStorage =
        OSAllocatedUnfairLock<(@Sendable (String, String) -> Void)?>(initialState: nil)
    nonisolated private static let _thinkingUnsupportedWarningHookStorage =
        OSAllocatedUnfairLock<(@Sendable (String, String) -> Void)?>(initialState: nil)
    nonisolated private static let _toolDispatchLogHookStorage =
        OSAllocatedUnfairLock<(@Sendable (String, [String: String]) -> Void)?>(initialState: nil)

    /// Test-only hook invoked alongside `Log.inference.warning` when
    /// `jsonMode=true` is requested on a backend whose capabilities report
    /// `supportsNativeJSONMode == false`. Receives `(backendTypeName, message)`.
    ///
    /// Production callers never set this; it exists so unit tests can verify
    /// the silent-ignore warning is emitted without standing up an OSLogStore
    /// reader. Tests must reset it in `tearDown` to avoid cross-test leakage.
    nonisolated static var jsonModeUnsupportedWarningHook: (@Sendable (String, String) -> Void)? {
        get { _jsonModeUnsupportedWarningHookStorage.withLock { $0 } }
        set { _jsonModeUnsupportedWarningHookStorage.withLock { $0 = newValue } }
    }

    /// Test-only hook invoked alongside `Log.inference.warning` when a request
    /// passes `tools` to a backend whose capabilities report
    /// `supportsToolCalling == false`. Receives `(backendTypeName, message)`.
    ///
    /// Mirrors `jsonModeUnsupportedWarningHook`. The motivation is the same:
    /// tools are silently dropped on incapable backends, and without a signal
    /// the model spins on "I cannot access tools" while the host wonders why
    /// its registry is never invoked. Tests must reset this in `tearDown`.
    nonisolated static var toolsUnsupportedWarningHook: (@Sendable (String, String) -> Void)? {
        get { _toolsUnsupportedWarningHookStorage.withLock { $0 } }
        set { _toolsUnsupportedWarningHookStorage.withLock { $0 = newValue } }
    }

    /// Test-only hook invoked alongside `Log.inference.warning` when a request
    /// passes thinking-only hints to a backend whose capabilities report
    /// `supportsThinking == false`. Receives `(backendTypeName, message)`.
    ///
    /// Unsupported thinking hints are not fatal because older callers may set
    /// a default budget globally, but they must never be silently ignored.
    /// Tests must reset this in `tearDown` to avoid cross-test leakage.
    nonisolated static var thinkingUnsupportedWarningHook: (@Sendable (String, String) -> Void)? {
        get { _thinkingUnsupportedWarningHookStorage.withLock { $0 } }
        set { _thinkingUnsupportedWarningHookStorage.withLock { $0 = newValue } }
    }

    /// Test-only hook invoked alongside `Log.inference.info` for each tool
    /// dispatch lifecycle log line (`tool_dispatch_started` /
    /// `tool_dispatch_completed`). Receives `(eventName, fields)` where
    /// `fields` mirrors the structured fields of the OSLog message.
    ///
    /// Production callers never set this; it exists so unit tests can verify
    /// the structured log output without standing up an OSLogStore reader.
    /// Tests must reset it in `tearDown` to avoid cross-test leakage.
    nonisolated static var toolDispatchLogHook: (@Sendable (String, [String: String]) -> Void)? {
        get { _toolDispatchLogHookStorage.withLock { $0 } }
        set { _toolDispatchLogHookStorage.withLock { $0 = newValue } }
    }

    // MARK: - Queue Types (Private)

    private struct QueuedRequest {
        let token: GenerationRequestToken
        let priority: GenerationPriority
        let requestGroupID: UUID?
        /// Structured conversation history. Carries thinking signatures and
        /// tool parts intact so cloud backends with structured wire formats
        /// (Anthropic) can replay them on multi-turn requests; text-only
        /// backends collapse this to `(role, content)` at their boundary.
        let messages: [StructuredMessage]
        let systemPrompt: String?
        let config: GenerationConfig
        /// Per-request runtime hints (JSON mode, thinking markers, structured
        /// output, RAG documents, run-token ceiling, prompt capture). Split out
        /// of ``GenerationConfig`` in #2152 so the config stays losslessly
        /// `Codable`; carried alongside it here.
        let hints: GenerationRuntimeHints
        let stream: GenerationStream
        /// Per-request handoff detector, captured at enqueue time. When set, it
        /// is used for this request's dispatch loop instead of the queue-level
        /// ``handoffDetector``. This closes the per-turn race where two
        /// concurrent turns mutating the shared queue-level detector clobbered
        /// each other between enqueue and stream consumption (#1494). `nil`
        /// falls back to the queue-level default for legacy single-turn callers.
        let handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?
        /// Per-request pre-tool-use hook, captured at enqueue time. See
        /// ``handoffDetector`` for the rationale. `nil` falls back to the
        /// queue-level ``preToolUseHook``.
        let preToolUseHook: (@Sendable (_ toolName: String, _ arguments: String, _ requestGroupID: UUID?) async -> PreToolUseOutcome)?
        /// When non-nil, this request dispatches to this host-owned backend
        /// instead of the primary ``currentBackend`` (the #799 Deep route).
        /// `nil` (default) routes to the primary backend. The routed backend is
        /// host-managed and is **not** tracked by the load coordinator, so the
        /// `isBackendLoaded` gate is skipped for routed requests.
        let routedBackend: (any InferenceBackend)?
    }

    // MARK: - Queue State (Private)

    private var nextGenerationToken: GenerationRequestToken = .zero
    private var requestQueue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?
    private var activeTask: Task<Void, Never>?
    private var continuations: [GenerationRequestToken: AsyncThrowingStream<GenerationEvent, Error>.Continuation] = [:]
    private let maxQueueDepth = 8

    /// Fan-out registry for secondary event consumers installed via
    /// ``addEventTap(bufferingPolicy:)`` (#2206). Broadcasts every
    /// ``GenerationEvent`` an `enqueue()`-driven request emits — independent
    /// of that request's own per-token stream, so a slow tap consumer never
    /// stalls generation and installing a tap never competes with the
    /// request's own listener.
    ///
    /// There are exactly two broadcast sites, both of which also yield to the
    /// request's own continuation: the `yieldEvent` closure in
    /// ``runToolDispatchLoop(request:)`` (which forwards every backend/queue
    /// event for the turn) and ``pauseWhileThermalCritical(token:)`` (whose
    /// `.throttleDiagnostic` is emitted between the loop's stream-consumption
    /// awaits, outside that closure). Keep any future direct
    /// `continuations[...]?.yield(...)` in step with a matching
    /// `eventTaps.broadcast(...)` so the tap never silently under-reports.
    private let eventTaps = GenerationEventTapRegistry()

    /// Timestamp of the most recent queue activity: enqueue, dequeue-to-active, or
    /// completion. Initialized to `.distantPast` so `idleDuration` is always
    /// meaningful even before the first request.
    private var lastActivityTimestamp: Date = .distantPast

    /// Seconds elapsed since the most recent generation activity. Returns `.infinity`
    /// when no generation has ever occurred so a freshly started service is treated
    /// as maximally idle by the keep-alive policy.
    var idleDuration: TimeInterval {
        guard lastActivityTimestamp != .distantPast else { return .infinity }
        return Date.now.timeIntervalSince(lastActivityTimestamp)
    }

    // MARK: - Computed

    var hasQueuedRequests: Bool { !requestQueue.isEmpty }

    /// Number of requests currently waiting in the queue (not including the
    /// active request being generated). Exposed publicly via `InferenceService`.
    var queuedRequestCount: Int { requestQueue.count }

    /// Timestamp of the most recent queue activity.
    var lastActivityAt: Date { lastActivityTimestamp }

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

    /// Finishes every registered ``addEventTap(bufferingPolicy:)`` consumer
    /// so a drain task iterating the tap's `AsyncStream` observes normal
    /// termination rather than hanging forever once this queue (and the
    /// owning `InferenceService`) is deallocated. `deinit` is always
    /// `nonisolated`, and ``GenerationEventTapRegistry`` is `Sendable` and
    /// internally lock-guarded, so this is safe to call here.
    deinit {
        eventTaps.finishAll()
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
    /// including thinking signatures) through to the backend boundary on
    /// ``GenerationRuntimeHints/history``. Backends read the structured form
    /// directly, or derive the flattened `(role, content)` / tool-aware shapes
    /// from it per call (#2312).
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

        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
        )
        config.maxThinkingTokens = maxThinkingTokens
        let hints = GenerationRuntimeHints(jsonMode: jsonMode)

        Self.warnIfThinkingUnsupported(backend: backend, config: config, hints: hints)

        return try dispatchToBackend(
            backend: backend,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
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
        config: GenerationConfig,
        hints: GenerationRuntimeHints = GenerationRuntimeHints()
    ) throws -> GenerationStream {
        try generateWithConfig(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
        )
    }

    /// Structured-message variant of ``generateWithConfig(messages:...)``.
    ///
    /// When `backendOverride` is non-nil the request dispatches to that
    /// host-owned backend instead of ``currentBackend`` (the #799 Deep route).
    /// `nil` (default) preserves the existing primary-backend behaviour.
    func generateWithConfig(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints = GenerationRuntimeHints(),
        backendOverride: (any InferenceBackend)? = nil
    ) throws -> GenerationStream {
        guard let backend = backendOverride ?? currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        Self.warnIfThinkingUnsupported(backend: backend, config: config, hints: hints)

        return try dispatchToBackend(
            backend: backend,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
        )
    }

    // MARK: - Backend dispatch (Private)

    /// Single pre-dispatch chokepoint for the native-JSON-mode capability
    /// check. Backends without native JSON-mode support silently ignore the
    /// flag and return plain text, so we warn once per request here rather
    /// than in each backend. Callers can branch on
    /// `backend.capabilities.supportsNativeJSONMode` programmatically to
    /// suppress the warning by not setting the flag in the first place.
    private static func warnIfJSONModeUnsupported(
        backend: InferenceBackend,
        hints: GenerationRuntimeHints
    ) {
        guard hints.jsonMode, !backend.capabilities.supportsNativeJSONMode else { return }
        let backendType = String(describing: type(of: backend))
        let message = "GenerationQueue: jsonMode=true requested but \(backendType) does not support native JSON mode (capabilities.supportsNativeJSONMode == false); the flag will be ignored and the response will be plain text. Check `backend.capabilities.supportsNativeJSONMode` before setting `hints.jsonMode`."
        Log.inference.warning("\(message, privacy: .public)")
        Self.jsonModeUnsupportedWarningHook?(backendType, message)
    }

    private static func warnIfThinkingUnsupported(
        backend: InferenceBackend,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) {
        guard !backend.capabilities.supportsThinking else { return }

        var requestedHints: [String] = []
        if config.maxThinkingTokens != nil {
            requestedHints.append("maxThinkingTokens")
        }
        if hints.thinkingMarkers != nil {
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
    /// Performs the optional exact-token pre-flight + trim loop, threads the
    /// structured history onto ``GenerationRuntimeHints/history``, and invokes
    /// ``InferenceBackend/generate(...)`` — which consumes it on the call stack
    /// (#2312). Backends derive the flattened `(role, content)` / tool-aware
    /// shapes from it as needed.
    private func dispatchToBackend(
        backend: InferenceBackend,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config rawConfig: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        // Fill the effective stop sequences from the active template's defaults
        // when the caller set none, for prompt-template backends (#1944). The
        // merged list rides on the dispatched config so companion backends that
        // honour stop strings can cut at the turn boundary; in-core backends may
        // ignore it (documented as ignored, like `seed`).
        let config = backend.capabilities.requiresPromptTemplate
            ? applyingTemplateStopSequences(to: rawConfig)
            : rawConfig
        Self.warnIfJSONModeUnsupported(backend: backend, hints: hints)

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
                renderer: promptRenderer
            ).exactPreflightAndTrim(
                counter: counter,
                backend: backend,
                messages: messages,
                systemPrompt: Self.toolAugmentedSystemPrompt(
                    renderer: promptRenderer,
                    systemPrompt: systemPrompt,
                    backend: backend,
                    config: config
                ),
                config: config,
                hints: hints
            )
            // Thread the (post-trim) conversation history to the backend on the
            // call stack via `hints.history` — never via shared instance state,
            // so concurrent requests against one backend can't leak each other's
            // history (#2312).
            var hintsWithHistory = hints
            hintsWithHistory.history = result.trimmedMessages
            let stream = try backend.generateEnforcingCapabilities(
                prompt: result.prompt,
                systemPrompt: nil,
                config: config,
                hints: hintsWithHistory
            )
            if hints.captureRenderedPrompt {
                return Self.prependingPromptRendered(text: result.prompt, to: stream)
            }
            return stream
        }

        // Non-TokenCountingBackend path: assemble prompt and forward.
        // For backends that require a prompt template, messages are formatted
        // into a single string. Otherwise the most recent user message is
        // passed directly and the system prompt goes through a separate channel.
        let flattened = GenerationHistoryInstaller.flatten(messages)
        let assembledPrompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            // Renders the model's real embedded Jinja chat template when present
            // and usable, falling back to the detected enum for templateless
            // models (#1811).
            let renderer = promptRenderer
            if backend.capabilities.supportsToolCalling && !config.tools.isEmpty {
                // A native tool template (embedded Jinja that references `tools`,
                // or the `.gemma4` enum) renders the tool block directly; every
                // other template gets the guidance folded into the system prompt
                // instead (#1856). `toolAugmentedSystemPrompt` keys that choice on
                // `renderer.rendersToolsNatively`, so passing `config.tools`
                // unconditionally never double-injects (#1909).
                let augmentedSystemPrompt = Self.toolAugmentedSystemPrompt(
                    renderer: renderer,
                    systemPrompt: systemPrompt,
                    backend: backend,
                    config: config
                )
                assembledPrompt = try renderer.render(
                    messages: messages,
                    systemPrompt: augmentedSystemPrompt,
                    tools: config.tools,
                    documents: hints.documents,
                    renderingMode: hints.renderingMode
                )
            } else {
                assembledPrompt = try renderer.render(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    documents: hints.documents,
                    renderingMode: hints.renderingMode
                )
            }
            effectiveSystemPrompt = nil
        } else {
            assembledPrompt = flattened.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        // Thread the conversation history to the backend on the call stack via
        // `hints.history` — never via shared instance state, so concurrent
        // requests against one backend can't leak each other's history (#2312).
        var hintsWithHistory = hints
        hintsWithHistory.history = messages

        let stream = try backend.generateEnforcingCapabilities(
            prompt: assembledPrompt,
            systemPrompt: effectiveSystemPrompt,
            config: config,
            hints: hintsWithHistory
        )
        if hints.captureRenderedPrompt {
            return Self.prependingPromptRendered(text: assembledPrompt, to: stream)
        }
        return stream
    }

    /// Wraps a `GenerationStream` to emit a single `.promptRendered(text:)` event
    /// before forwarding all events from the upstream stream.
    ///
    /// Used only when `GenerationConfig.captureRenderedPrompt` is `true`. The
    /// wrapper forwards errors faithfully — if the upstream stream throws, the
    /// wrapped stream re-throws the same error so callers see no difference in
    /// error handling.
    private static func prependingPromptRendered(
        text: String,
        to upstream: GenerationStream
    ) -> GenerationStream {
        let wrapped = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            let task = Task {
                continuation.yield(.promptRendered(text: text))
                do {
                    for try await event in upstream.events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return GenerationStream(wrapped)
    }

    /// Folds the canonical tool-preference preamble into `systemPrompt` when the
    /// selected prompt template does **not** render tools natively (#1856).
    ///
    /// `GenerationQueue` passes `config.tools` to `PromptTemplate.format(…:tools:)`
    /// for every prompt-template backend, but only `.gemma4` consumes them — it
    /// emits a native `<|tool>` block. Every other template (`.llama3`, `.chatML`,
    /// `.mistral`, `.phi`, `.gemma`, `.alpaca`) silently discards the array, so a
    /// local non-Gemma model never sees the tool definitions unless the host
    /// hand-injects them. That hand-injection was the documented manual recipe
    /// (docs/LOCAL-TOOL-CALLING.md, Step 1); this folds it in automatically using
    /// the same `ToolSystemPromptBuilder.preferTools(for:)` preamble.
    ///
    /// Returns `systemPrompt` unchanged when: tools are empty, the backend does
    /// not support tool calling, or the prompt that will actually be rendered
    /// carries tools natively (no double-injection). Otherwise prepends the
    /// preamble — matching the documented `preamble + "\n\n" + appSystemPrompt`
    /// shape.
    ///
    /// The native-vs-fold decision is keyed on ``PromptRenderer/rendersToolsNatively``
    /// rather than the bare enum flag: once an embedded Jinja template renders
    /// tools (#1909), the enum's `.gemma4`-only flag is the wrong signal — the
    /// renderer knows whether the executing path emits a native tool block.
    static func toolAugmentedSystemPrompt(
        renderer: PromptRenderer,
        systemPrompt: String?,
        backend: InferenceBackend,
        config: GenerationConfig
    ) -> String? {
        guard backend.capabilities.supportsToolCalling,
              !config.tools.isEmpty,
              !renderer.rendersToolsNatively else {
            return systemPrompt
        }

        let preamble = ToolSystemPromptBuilder.preferTools(for: config.tools)
        // `preferTools` returns "" only when tools is empty, which is guarded
        // above — but stay defensive so an empty preamble never strands a stray
        // separator in front of the host's prompt.
        guard !preamble.isEmpty else { return systemPrompt }

        guard let systemPrompt, !systemPrompt.isEmpty else { return preamble }
        return preamble + "\n\n" + systemPrompt
    }

    // MARK: - Generation Queue

    /// The single value-typed enqueue entry point.
    ///
    /// Takes a pre-built ``GenerationConfig`` plus the small non-config triple
    /// (`priority`, `requestGroupID`, and the structured `messages`/`systemPrompt`).
    /// Every parameterized convenience overload funnels here after assembling a
    /// config, so the capability gates, queue-depth check, token/stream
    /// construction, and FIFO+priority insertion live in exactly one place.
    func enqueue(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        config: GenerationConfig,
        hints: GenerationRuntimeHints = GenerationRuntimeHints(),
        priority: GenerationPriority = .normal,
        requestGroupID: UUID? = nil,
        handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)? = nil,
        preToolUseHook: (@Sendable (_ toolName: String, _ arguments: String, _ requestGroupID: UUID?) async -> PreToolUseOutcome)? = nil,
        routedBackend: (any InferenceBackend)? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        // When a routed (Deep, #799) backend is supplied, dispatch there and
        // skip the `isBackendLoaded` gate — that gate tracks only the primary
        // backend's load coordinator, whereas the routed backend is host-owned
        // and lifecycle-managed entirely outside InferenceService.
        guard let backend = routedBackend ?? currentBackend,
              routedBackend != nil || isBackendLoaded else {
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

        // Derive a tool-call GBNF grammar (#1859) when the backend supports
        // grammar-constrained sampling, tools are present, and the caller did
        // NOT supply an explicit grammar. An explicit caller grammar always
        // wins — we never overwrite a host-authored string. The derived grammar
        // pins the emitted tool-call envelope's `"name"` to the enum of the
        // supplied tool names so the model can't drift off-format.
        //
        // Injection is `toolChoice`-aware (#1961). A tool-call-only union forces
        // a structured call (every branch begins with `{`), which is correct for
        // `.required` / `.tool(name:)` but wrong for `.auto`: it masks every
        // non-`{` first token, the decoder collapses onto EOS, and generation
        // stops at zero tokens (manifold-llama#55). So `.auto` gets the
        // prose-permitting grammar, `.tool(name:)` a single-tool union, and
        // `.none` no grammar at all.
        var config = config
        var hints = hints
        if config.grammar == nil,
           !config.tools.isEmpty,
           backend.capabilities.supportsGrammarConstrainedSampling {
            let mode: ToolGrammarBuilder.Mode?
            switch config.toolChoice {
            case .auto:
                mode = .permissive
            case .required:
                mode = .strict(only: nil)
            case .tool(let name):
                mode = .strict(only: name)
            case .none:
                // `.none` means "must not call a tool" — injecting a tool-call
                // grammar would do the opposite. Leave sampling unconstrained.
                mode = nil
            @unknown default:
                // An unrecognised future choice mode: fall back to the
                // permissive (`.auto`) grammar rather than guessing at a
                // stricter constraint the mode doesn't actually ask for.
                mode = .permissive
            }
            if let mode,
               let derived = ToolGrammarBuilder().buildGrammar(for: config.tools, mode: mode) {
                config.grammar = derived
            }
        }

        // Structured-output routing (#1915). When a caller has staged a
        // structured-output target on the config, this is where it gets lowered
        // into the strongest mechanism the *active* backend supports — the
        // first production caller of `StructuredOutputRouter`. `respond(_:to:)`
        // stages the target; the queue resolves it here because only the queue
        // knows which backend will actually serve the request.
        var systemPrompt = systemPrompt
        // The strategy the router actually chose for the serving backend, so it
        // can be surfaced on the returned stream as the single source of truth
        // (`respond(_:to:)` reads it rather than recomputing against a possibly
        // different capability set).
        var selectedStructuredStrategy: StructuredOutputStrategy?
        if let staged = hints.structuredOutput,
           let target = Self.structuredOutputTarget(
               from: staged,
               capabilities: backend.capabilities
           ) {
            let strategy = StructuredOutputRouter.selectStrategy(
                capabilities: backend.capabilities,
                target: target
            )
            selectedStructuredStrategy = strategy
            switch strategy {
            case .gbnf(let grammar):
                // An explicit caller grammar always wins; only lower when the
                // slot is free so we never clobber a host-authored string.
                if config.grammar == nil { config.grammar = grammar }
                // The grammar is the constraint — drop the strategy hint so a
                // cloud encoder downstream doesn't also try to apply a schema.
                hints.structuredOutput = nil
            case .jsonSchema(let schema):
                // Leave the strategy on the hints so the cloud strict-schema
                // encoder (sibling #1918) honors it on the wire.
                hints.structuredOutput = .jsonSchema(schema)
            case .jsonPrompting:
                // No backend-level constraint available — fall back to a
                // prompt-level instruction so weak backends still get steered.
                if let schema = target.jsonSchema, !schema.isEmpty {
                    systemPrompt = Self.appendingJSONSchemaInstruction(
                        to: systemPrompt,
                        schema: schema
                    )
                }
                hints.structuredOutput = nil
            case .guided:
                // No config lowering needed here (#2354): `hints.structuredOutput`
                // is already `.guided(type)` from staging, and that's exactly
                // what the guided-capable backend (FoundationBackend) reads to
                // build its native GuidedGeneration schema.
                break
            }
        }

        let token = GenerationRequestToken(rawValue: nextGenerationToken.rawValue + 1)
        nextGenerationToken = token

        var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation!
        let rawStream = AsyncThrowingStream<GenerationEvent, Error> { continuation = $0 }
        let stream = GenerationStream(rawStream)
        stream.setPhase(.queued)
        stream.structuredOutputStrategy = selectedStructuredStrategy
        continuations[token] = continuation

        Self.warnIfThinkingUnsupported(backend: backend, config: config, hints: hints)

        let request = QueuedRequest(
            token: token,
            priority: priority,
            requestGroupID: requestGroupID,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints,
            stream: stream,
            handoffDetector: handoffDetector,
            preToolUseHook: preToolUseHook,
            routedBackend: routedBackend
        )

        if let insertIdx = requestQueue.firstIndex(where: { $0.priority < priority }) {
            requestQueue.insert(request, at: insertIdx)
        } else {
            requestQueue.append(request)
        }

        lastActivityTimestamp = Date()
        drainQueue()
        return (token: token, stream: stream)
    }

    /// Reconstructs a ``StructuredOutputTarget`` from a strategy a caller staged
    /// on ``GenerationConfig/structuredOutput``.
    ///
    /// `respond(_:to:)`/`structured(_:messages:)` stage `.guided(T.self)` (#2354)
    /// so a guided-capable backend (Foundation) can receive the concrete type;
    /// this function recovers the type's JSON Schema from its `SchemaProviding`
    /// conformance so non-guided backends still get a full target — the same
    /// grammar-lowering / jsonSchema fallback the `.jsonSchema` case below always
    /// had. When the active backend supports grammar-constrained sampling, the
    /// schema is lowered to GBNF here so the router can upgrade to the strongest
    /// mechanism. Doing the lowering inside the queue (rather than staging a
    /// grammar on `config.grammar`) keeps the caller's `config.grammar` slot
    /// untouched — a schema-only backend never sees a stray grammar it would
    /// reject. Returns `nil` for `.gbnf` (already a grammar, nothing to
    /// re-route) and `.jsonPrompting` (no re-routable payload).
    static func structuredOutputTarget(
        from strategy: StructuredOutputStrategy,
        capabilities: BackendCapabilities
    ) -> StructuredOutputTarget? {
        switch strategy {
        case .jsonSchema(let schema):
            let grammar: String?
            if capabilities.supportsGrammarConstrainedSampling,
               let schemaValue = Self.decodeSchema(schema) {
                grammar = ToolGrammarBuilder().buildSchemaGrammar(for: schemaValue)
            } else {
                grammar = nil
            }
            return StructuredOutputTarget(gbnfGrammar: grammar, jsonSchema: schema)
        case .guided(let type):
            // `respond`/`structured` only ever stage `.guided` for a concrete
            // `T: SchemaProviding` (enforced by their generic constraints), so
            // this cast is expected to succeed; falling back to a bare
            // guided-only target (no jsonSchema/gbnfGrammar) rather than
            // crashing is defensive against a hypothetical future caller that
            // stages `.guided` without the conformance.
            guard let provider = type as? any SchemaProviding.Type else {
                return StructuredOutputTarget(guidedType: type)
            }
            let schemaValue = provider.jsonSchema
            let schemaString: String?
            do {
                schemaString = try InferenceService.encodeSchema(schemaValue)
            } catch {
                Log.inference.warning(
                    "StructuredOutputRouter: failed to encode \(String(describing: type))'s schema for the non-guided fallback path: \(String(describing: error), privacy: .public)"
                )
                schemaString = nil
            }
            let grammar: String?
            if capabilities.supportsGrammarConstrainedSampling {
                grammar = ToolGrammarBuilder().buildSchemaGrammar(for: schemaValue)
            } else {
                grammar = nil
            }
            return StructuredOutputTarget(gbnfGrammar: grammar, guidedType: type, jsonSchema: schemaString)
        case .gbnf, .jsonPrompting:
            return nil
        }
    }

    /// Decodes a staged JSON-schema string back into a ``JSONSchemaValue`` for
    /// GBNF lowering. Returns `nil` on malformed input so the caller falls back
    /// to a non-grammar strategy rather than crashing.
    private static func decodeSchema(_ schema: String) -> JSONSchemaValue? {
        guard let data = schema.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(JSONSchemaValue.self, from: data)
        } catch {
            Log.inference.warning(
                "StructuredOutputRouter: failed to decode staged JSON schema for GBNF lowering: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Appends a JSON-schema instruction to a system prompt for the
    /// prompt-level structured-output fallback (`.jsonPrompting`).
    static func appendingJSONSchemaInstruction(to systemPrompt: String?, schema: String) -> String {
        let instruction = """
        You must respond with a single JSON object that conforms exactly to this JSON Schema. \
        Output only the JSON object — no prose, no code fences.
        JSON Schema:
        \(schema)
        """
        guard let existing = systemPrompt, !existing.isEmpty else { return instruction }
        return existing + "\n\n" + instruction
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
            maxToolIterations: maxToolIterations
        )
        config.maxThinkingTokens = maxThinkingTokens
        config.grammar = grammar
        return config
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
        lastActivityTimestamp = Date()
        next.stream.setPhase(.connecting)

        activeTask = Task { [weak self] in
            guard let self else { return }

            var thrownError: Error?
            defer {
                // Atomic post-turn state transition (issue #1986). This whole
                // `defer` body runs as a single `@MainActor`-isolated, non-
                // suspending block, so no other `@MainActor` work interleaves
                // *within* it. The ordering inside it is still load-bearing:
                // clear the active-slot flags (`activeRequest`, `activeTask`,
                // `isGenerating`) BEFORE finishing the continuation. Finishing
                // the continuation can wake a consumer whose stream-end handler
                // hops back onto the main actor and calls `enqueue()`; if that
                // re-entrant caller ran while `isGenerating`/`activeRequest`
                // still reflected the dying turn, it would observe a stale
                // mid-tear-down state and either queue a turn that should have
                // activated or race a double-activation. Clearing first means
                // any such observer sees a clean, idle queue.
                let isCurrentSlot = self.activeRequest?.token == next.token
                if isCurrentSlot {
                    self.lastActivityTimestamp = Date()
                    self.activeRequest = nil
                    self.activeTask = nil
                    self.isGenerating = false
                }

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

                // Drain only after the slot is idle and the stream has been
                // finished, so a queued follow-up activates against a clean
                // slot rather than mid-transition.
                if isCurrentSlot {
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
    /// Emits `GenerationEvent.throttleDiagnostic` exactly once per pause
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
        //
        // Fan out to BOTH the request's own stream AND the secondary event
        // taps (#2206), exactly as the `yieldEvent` closure in
        // `runToolDispatchLoop` does for every other event. This emission is
        // the one `GenerationEvent` produced outside that closure (the pause
        // loop runs between the loop's stream-consumption awaits), so without
        // the explicit `eventTaps.broadcast` here a tap trace would silently
        // omit `.throttleDiagnostic` during a thermal-critical generation —
        // the only gap in the "every enqueue()-driven event reaches the tap"
        // guarantee. Yield to the own-continuation once (no double-yield).
        let throttleEvent = GenerationEvent.throttleDiagnostic(reason: "thermalState=.critical")
        self.continuations[token]?.yield(throttleEvent)
        self.eventTaps.broadcast(throttleEvent)
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
        // Prefer the per-request closures captured at enqueue time over the
        // queue-level defaults. The runtime threads detector + pre-tool-use
        // hook in per request (#1494) so two concurrent turns can't clobber a
        // shared mutable detector between enqueue and stream consumption. A
        // `nil` per-request closure falls back to the queue-level default for
        // legacy single-turn callers that still call setHandoffDetector(_:) /
        // setPreToolUseHook(_:).
        let effectiveHandoffDetector = request.handoffDetector ?? handoffDetector
        let effectivePreToolUseHook = request.preToolUseHook ?? preToolUseHook
        // Routed (Deep, #799) backend for this request, if any. When set, both
        // the tool loop's backend reader and the generate closure dispatch here
        // instead of the primary backend. nil = primary route (unchanged).
        let routedBackend = request.routedBackend

        // Bind the per-request hook closures explicitly so the type checker
        // doesn't have to infer them inside the giant init expression below.
        let boundPreToolUseHook: PreToolUseHook? = effectivePreToolUseHook.map { hook in
            let requestGroupID = request.requestGroupID
            return { @Sendable toolName, arguments, _ in
                await hook(toolName, arguments, requestGroupID)
            }
        }
        let loop = GenerationToolDispatchLoop(
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate,
            currentBackend: { [weak self] in routedBackend ?? self?.currentBackend },
            generateWithConfig: { [weak self] messages, systemPrompt, config, hints in
                guard let self else {
                    throw InferenceError.inferenceFailure("Generation queue deallocated")
                }
                return try self.generateWithConfig(
                    structuredMessages: messages,
                    systemPrompt: systemPrompt,
                    config: config,
                    hints: hints,
                    backendOverride: routedBackend
                )
            },
            yieldEvent: { [weak self] event in
                self?.continuations[request.token]?.yield(event)
                self?.eventTaps.broadcast(event)
                if case .token = event, request.stream.phase != .streaming {
                    request.stream.setPhase(.streaming)
                }
            },
            pauseWhileThermalCritical: { [weak self] token in
                await self?.pauseWhileThermalCritical(token: token)
            },
            handoffDetector: effectiveHandoffDetector.map { detector in
                { [requestGroupID = request.requestGroupID] call in
                    detector(requestGroupID, call)
                }
            },
            preToolUseHook: boundPreToolUseHook
        )

        try await loop.run(
            token: request.token,
            messages: request.messages,
            systemPrompt: request.systemPrompt,
            config: request.config,
            hints: request.hints
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
            (activeRequest?.routedBackend ?? currentBackend)?.stopGeneration()
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

    func discardRequests(notMatching requestGroupID: UUID) async {
        requestQueue.removeAll { req in
            guard let reqGroup = req.requestGroupID, reqGroup != requestGroupID else { return false }
            req.stream.setPhase(.failed("Session changed"))
            finishAndDiscard(req.token, error: InferenceError.inferenceFailure("Session changed"))
            return true
        }
        if let active = activeRequest,
           let activeGroup = active.requestGroupID,
           activeGroup != requestGroupID {
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
        (activeRequest?.routedBackend ?? currentBackend)?.stopGeneration()
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

    // MARK: - Secondary event taps (#2206)

    /// Installs a secondary multicast tap on every ``GenerationEvent`` this
    /// queue emits across ALL `enqueue()`-driven requests, independent of any
    /// specific request's own stream.
    ///
    /// See ``InferenceService/addGenerationEventTap(bufferingPolicy:)`` for
    /// the public entry point and rationale — this is the queue-level
    /// implementation it delegates to.
    func addEventTap(
        bufferingPolicy: AsyncStream<GenerationEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<GenerationEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [eventTaps] continuation in
            let id = eventTaps.register(continuation)
            continuation.onTermination = { _ in
                eventTaps.deregister(id)
            }
        }
    }

}
