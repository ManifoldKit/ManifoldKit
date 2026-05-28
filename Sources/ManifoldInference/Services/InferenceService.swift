import Foundation
import Observation

/// A factory closure that creates a local inference backend for the given model type.
/// Return `nil` if this factory does not handle the given type.
public typealias BackendFactory = @MainActor (ModelType) -> (any InferenceBackend)?

/// A factory closure that creates a cloud inference backend for the given API provider.
/// Return `nil` if this factory does not handle the given provider.
public typealias CloudBackendFactory = @MainActor (APIProvider) -> (any InferenceBackend)?

/// Readiness state for the primary model managed by ``InferenceService``.
public enum ModelLoadReadinessState: Equatable, Sendable {
    /// No model is loaded and no load operation is currently in flight.
    case idle
    /// A model load is currently in flight.
    case loading(progress: Double?)
    /// The primary model is loaded and ready for generation.
    case ready

    /// Whether generation can be attempted against the primary backend.
    public var isReady: Bool {
        self == .ready
    }
}

/// Orchestrates inference across multiple backends.
///
/// Selects the appropriate backend based on model format and delegates all
/// loading, generation, and lifecycle management to it. Views and view models
/// interact only with this service, never with backends directly.
///
/// Backends are pluggable via `registerBackendFactory` and
/// `registerCloudBackendFactory`. This keeps ManifoldCore free of any
/// direct dependency on MLX, llama.cpp, Foundation Models, or cloud SDKs —
/// those are registered by the app or the ManifoldBackends target at startup.
///
/// ## Load lifecycle guarantees
///
/// - **Latest-wins requests**: each `loadModel` / `loadCloudBackend` call creates
///   a new load request token; only the newest in-flight token may commit.
/// - **Stale completion suppression**: if an older request finishes after a newer
///   request started, stale successes are unloaded and stale failures are ignored
///   for state transitions.
/// - **Unload/preemption invalidation**: `unloadModel()` invalidates all
///   outstanding requests so late completions cannot restore a model.
///
/// These guarantees are service-level coordination semantics. Backend-specific
/// threading/execution constraints (for example MLX generation's main-thread
/// requirement) are unchanged.
///
/// ## Generation queue guarantees
///
/// - **Sequential FIFO**: only one backend `generate()` call is active at a time.
///   The queue is processed sequentially regardless of backend type.
/// - **Priority ordering**: `.userInitiated` > `.normal` > `.background`.
///   Within the same priority, requests execute in FIFO order.
/// - **Session scoping**: requests carry an optional session ID.
///   `discardRequests(notMatching:)` cancels all requests not belonging to the
///   specified session. Requests with `nil` sessionID are session-agnostic.
/// - **Per-request cancellation**: `cancel(_:)` removes a queued request or stops
///   the active one, then drains the next item.
/// - **Max queue depth**: excess `enqueue()` calls throw. Default: 8.
/// - **Thermal gating**: `.background` requests are dropped when the device is
///   under `.serious` or `.critical` thermal pressure.
/// - **Auto-drain**: the queue drains automatically when each stream terminates.
@Observable
@MainActor
public final class InferenceService {

    // MARK: - Internal Coordinators

    private let lifecycle: ModelLifecycleCoordinator
    private let generation: GenerationQueue

    // MARK: - Memory Pressure Broadcasting

    /// Fan-out broadcaster for memory-pressure and model-lifecycle events.
    private let pressureBroadcaster = MemoryPressureBroadcaster()

    /// UUID of the most recently successfully loaded model.
    ///
    /// Updated immediately after a successful ``loadModel`` commit and cleared on
    /// ``unloadModel``. Used to populate the `modelID` field of ``MemoryPressureEvent``
    /// without threading `ModelInfo` all the way through the unload path.
    private var loadedModelID: UUID?

    // MARK: - Public Type Aliases (preserve InferenceService.GenerationRequestToken syntax)

    public typealias GenerationRequestToken = ManifoldInference.GenerationRequestToken
    public typealias GenerationPriority = ManifoldInference.GenerationPriority

    // MARK: - Published State (forwarded from coordinators)

    public var isModelLoaded: Bool { lifecycle.isModelLoaded }
    public var isGenerating: Bool { generation.isGenerating }
    public var activeBackendName: String? { lifecycle.activeBackendName }
    public var activeModelName: String? { lifecycle.activeModelName }
    public var modelLoadProgress: Double? { lifecycle.modelLoadProgress }
    public var modelLoadReadinessState: ModelLoadReadinessState {
        if lifecycle.isModelLoaded { return .ready }
        if let progress = lifecycle.modelLoadProgress { return .loading(progress: progress) }
        return .idle
    }

    /// The prompt template to apply for backends that require one (GGUF).
    public var selectedPromptTemplate: PromptTemplate {
        get { lifecycle.selectedPromptTemplate }
        set { lifecycle.selectedPromptTemplate = newValue }
    }

    // MARK: - Computed

    public var capabilities: BackendCapabilities? { lifecycle.capabilities }

    // MARK: - Deny Policy

    /// Policy applied when a ``ModelLoadPlan`` returns a ``ModelLoadPlan/Verdict/deny``
    /// verdict. Defaults to ``LoadDenyPolicy/platformDefault`` (iOS: `.throwError`,
    /// macOS: `.warnOnly`). Custom hooks receive the full plan so they can inspect
    /// `reasons` before deciding whether to proceed.
    public var denyPolicy: LoadDenyPolicy = .platformDefault {
        didSet { lifecycle.denyPolicy = denyPolicy }
    }

    // MARK: - Fast-Backend Routing

    /// Optional secondary backend used for lightweight subtasks
    /// (turn summarization, session naming, etc).
    ///
    /// When set, callers using ``runFastOrPrimary(prompt:systemPrompt:config:preferFast:)``
    /// (or future internal opt-in subtask paths) dispatch here first and fall
    /// back to the primary backend on failure. Hosts typically configure a
    /// small, fast model (1B–3B) here while the primary handles user chat.
    ///
    /// Additive and opt-in: leaving this `nil` (the default) preserves all
    /// existing behaviour — every call goes to the primary backend.
    ///
    /// The fast backend is **not** registered through the load-coordinator;
    /// hosts pre-load it themselves (typically at app start) and assign the
    /// already-loaded instance here. ``InferenceService`` does not unload,
    /// reset, or otherwise manage the lifecycle of this backend.
    public var fastBackend: (any InferenceBackend)?

    // MARK: - Backend Registration

    public func registerBackendFactory(_ factory: @escaping BackendFactory) {
        lifecycle.registerBackendFactory(factory)
    }

    public func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
        lifecycle.registerCloudBackendFactory(factory)
    }

    public func declareSupport(for modelType: ModelType) {
        lifecycle.declareSupport(for: modelType)
    }

    public func declareSupport(for provider: APIProvider) {
        lifecycle.declareSupport(for: provider)
    }

    // MARK: - Model Lifecycle

    /// Loads a model using a precomputed ``ModelLoadPlan``.
    ///
    /// Build the plan with ``ModelLoadPlan/compute(for:requestedContextSize:strategy:)``
    /// or the ``ModelLoadPlan/compute(for:requestedContextSize:)`` overload that accepts
    /// a ``ModelInfo`` value and picks the strategy automatically.
    public func loadModel(
        from modelInfo: ModelInfo,
        plan: ModelLoadPlan
    ) async throws {
        ensureProviderWired()
        generation.stopGeneration()
        try await lifecycle.loadModel(from: modelInfo, plan: plan)
        // Track the loaded model so willUnload/didUnload can carry the same UUID.
        loadedModelID = modelInfo.id
        pressureBroadcaster.send(.didReload(modelID: modelInfo.id))
    }

    /// Loads a cloud API backend from an `APIEndpointRecord` configuration.
    ///
    /// Follows the same latest-wins/stale-suppression semantics as `loadModel`.
    public func loadCloudBackend(from endpoint: APIEndpointRecord) async throws {
        ensureProviderWired()
        generation.stopGeneration()
        try await lifecycle.loadCloudBackend(from: endpoint)
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Also cancels in-flight generation and preempts outstanding load requests.
    ///
    /// Emits ``MemoryPressureEvent/willUnload(modelID:reason:)`` before unloading and
    /// ``MemoryPressureEvent/didUnload(modelID:reason:)`` after. The default reason is
    /// ``UnloadReason/userRequested``; call ``unloadModel(reason:)`` from internal paths
    /// where the trigger is known.
    public func unloadModel() {
        unloadModel(reason: .userRequested)
    }

    /// Internal variant of ``unloadModel()`` that carries an explicit ``UnloadReason``
    /// so pressure-driven unloads emit the correct event label.
    ///
    /// Package-visible so ``ChatViewModel`` can specify
    /// ``UnloadReason/criticalMemoryPressure`` when reacting to OS notifications.
    package func unloadModel(reason: UnloadReason) {
        ensureProviderWired()
        guard lifecycle.isModelLoaded else {
            // Nothing loaded — stop generation for safety but emit no lifecycle events.
            generation.stopGeneration()
            lifecycle.unloadModel()
            return
        }
        // Prefer the tracked UUID from the load path; fall back to a synthetic one for
        // backends installed via the debug init (which bypass loadModel(from:plan:)).
        let modelID = loadedModelID ?? UUID()
        pressureBroadcaster.send(.willUnload(modelID: modelID, reason: reason))
        generation.stopGeneration()
        lifecycle.unloadModel()
        pressureBroadcaster.send(.didUnload(modelID: modelID, reason: reason))
        loadedModelID = nil
    }

    /// Streams primary-model readiness transitions.
    ///
    /// The stream yields the current state immediately, then yields subsequent
    /// changes observed through Swift Observation. Values are buffered newest-only
    /// so callers interested in readiness never build an event backlog.
    public func modelLoadReadinessUpdates() -> AsyncStream<ModelLoadReadinessState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observer = ModelLoadReadinessObserver(service: self, continuation: continuation)
            continuation.onTermination = { _ in
                Task { @MainActor in observer.cancel() }
            }
            observer.start()
        }
    }

    /// Waits for an in-flight model load to finish before generation begins.
    ///
    /// - Returns: `true` when the model is already ready, or becomes ready within
    ///   the compatibility timeout window. Returns `false` when no load is in
    ///   progress, the load finishes without a ready model, timeout elapses, or
    ///   the waiting task is cancelled.
    public func waitUntilModelReady(
        maxPollCount: Int = 300,
        pollIntervalNanoseconds: UInt64 = 50_000_000
    ) async -> Bool {
        switch modelLoadReadinessState {
        case .ready:
            return true
        case .idle:
            return false
        case .loading:
            break
        }

        let timeoutNanoseconds = Self.modelReadyTimeoutNanoseconds(
            maxPollCount: maxPollCount,
            pollIntervalNanoseconds: pollIntervalNanoseconds
        )

        return await Self.waitUntilModelReady(
            readinessUpdates: modelLoadReadinessUpdates(),
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Waits for a supplied readiness stream to report that the model is ready.
    ///
    /// This overload is useful for hosts and tests that want the same generic
    /// readiness semantics as ``waitUntilModelReady(maxPollCount:pollIntervalNanoseconds:)``
    /// while injecting a synthetic stream at the Manifold boundary.
    public nonisolated static func waitUntilModelReady(
        readinessUpdates updates: AsyncStream<ModelLoadReadinessState>,
        maxPollCount: Int = 300,
        pollIntervalNanoseconds: UInt64 = 50_000_000
    ) async -> Bool {
        await waitUntilModelReady(
            readinessUpdates: updates,
            timeoutNanoseconds: modelReadyTimeoutNanoseconds(
                maxPollCount: maxPollCount,
                pollIntervalNanoseconds: pollIntervalNanoseconds
            )
        )
    }

    private nonisolated static func waitUntilModelReady(
        readinessUpdates updates: AsyncStream<ModelLoadReadinessState>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in updates {
                    if Task.isCancelled { return false }
                    switch state {
                    case .ready:
                        return true
                    case .idle:
                        return false
                    case .loading:
                        continue
                    }
                }
                return false
            }
            group.addTask {
                guard timeoutNanoseconds > 0 else { return false }
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - Generation

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. Use ``enqueue`` for
    /// user-facing chat generation that must be serialized.
    public func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false
    ) throws -> GenerationStream {
        ensureProviderWired()
        return try generation.generate(
            messages: messages,
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
    /// Carries ``MessagePart`` content (including thinking blocks with
    /// signatures) through to the backend boundary so cloud APIs that
    /// require structured replay (Anthropic extended thinking) can
    /// reconstruct prior turns without losing provider-supplied metadata.
    public func generate(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false
    ) throws -> GenerationStream {
        ensureProviderWired()
        return try generation.generate(
            structuredMessages: messages,
            systemPrompt: systemPrompt,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            maxThinkingTokens: maxThinkingTokens,
            jsonMode: jsonMode
        )
    }

    // MARK: - Generation Queue

    /// Enqueues a generation request from a typed ``Message`` slice using a
    /// pre-built ``GenerationConfig``, returning a token + stream pair.
    ///
    /// This is the value-typed entry point. Every sampling knob now lives on
    /// ``GenerationConfig`` rather than being spread across a ~18-parameter
    /// argument list, so adding a new knob is a one-line change on the config
    /// type instead of a thread-through across every enqueue signature. The
    /// parameterized overloads below remain as deprecated source-compatible
    /// builders that assemble a config and forward here.
    ///
    /// The stream starts in `.queued` phase and transitions to `.connecting`
    /// when the request reaches the front of the queue.
    ///
    /// Prefer ``Message`` literals over raw role/content tuples —
    /// `Message.system(_:)` / `.user(_:)` / `.assistant(_:)` cannot be
    /// misspelled, while raw `"systme"` typos pass the type checker and
    /// surface as silent backend errors.
    public func enqueue(
        messages: [Message],
        systemPrompt: String? = nil,
        config: GenerationConfig,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        ensureProviderWired()
        return try generation.enqueue(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            config: config,
            priority: priority,
            sessionID: sessionID
        )
    }

    /// Structured-message variant of ``enqueue(messages:config:priority:sessionID:)``.
    ///
    /// Threads ``StructuredMessage`` through the queue so cloud backends
    /// with structured wire formats (Anthropic) can replay prior assistant
    /// turns including their thinking blocks and signatures verbatim.
    public func enqueue(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        config: GenerationConfig,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        ensureProviderWired()
        return try generation.enqueue(
            structuredMessages: messages,
            systemPrompt: systemPrompt,
            config: config,
            priority: priority,
            sessionID: sessionID
        )
    }

    /// Parameterized enqueue retained as a source-compatible builder.
    ///
    /// Assembles a ``GenerationConfig`` from the individual sampling
    /// parameters and forwards to ``enqueue(messages:config:priority:sessionID:)``.
    @available(*, deprecated, message: "Build a GenerationConfig and call enqueue(messages:config:priority:sessionID:).")
    public func enqueue(
        messages: [Message],
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
            messages: messages,
            systemPrompt: systemPrompt,
            config: GenerationQueue.makeEnqueueConfig(
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

    /// Tuple-shaped enqueue retained for one minor while consumers migrate
    /// to the typed ``enqueue(messages:config:priority:sessionID:)`` overload.
    @available(*, deprecated, message: "Use [Message] with .system/.user/.assistant and a GenerationConfig — raw role strings are typo-prone.")
    public func enqueue(
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
        ensureProviderWired()
        return try generation.enqueue(
            structuredMessages: messages.map { StructuredMessage(role: $0.role, content: $0.content) },
            systemPrompt: systemPrompt,
            config: GenerationQueue.makeEnqueueConfig(
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                topK: nil,
                minP: nil,
                presencePenalty: nil,
                frequencyPenalty: nil,
                seed: nil,
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

    /// Parameterized structured-message enqueue retained as a source-compatible builder.
    @available(*, deprecated, message: "Build a GenerationConfig and call enqueue(structuredMessages:config:priority:sessionID:).")
    public func enqueue(
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
            config: GenerationQueue.makeEnqueueConfig(
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

    /// Cancels a specific generation request by token.
    ///
    /// If the token matches the active request, it is stopped and the next
    /// queued item begins. If queued, the request is removed without executing.
    public func cancel(_ token: GenerationRequestToken) {
        ensureProviderWired()
        generation.cancel(token)
    }

    public func discardRequests(notMatching sessionID: UUID) async {
        ensureProviderWired()
        await generation.discardRequests(notMatching: sessionID)
    }

    public var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        ensureProviderWired()
        return generation.lastTokenUsage
    }

    /// Requests that the current generation stop and cancels all queued requests.
    public func stopGeneration() {
        ensureProviderWired()
        generation.stopGeneration()
    }

    public var hasQueuedRequests: Bool {
        ensureProviderWired()
        return generation.hasQueuedRequests
    }

    public func resetConversation() {
        lifecycle.resetConversation()
    }

    /// Zeroes any KV-cache residue held by the active backend.
    ///
    /// Call after ``resetConversation()`` to close the window during which
    /// prior-turn key/value tensors remain in process memory. Each backend
    /// provides the best zeroing guarantee its runtime allows:
    ///
    /// - **LlamaBackend**: calls `llama_memory_clear(mem, true)` which zeros
    ///   the actual KV tensor data (key and value matrices).
    /// - **MLXBackend**: calls `Memory.clearCache()` to evict pooled Metal
    ///   GPU buffers; explicit zeroing is not available via the current MLX API.
    /// - **Cloud and Foundation backends**: no-op (secrets handled by
    ///   ``SecureBytes`` on the keychain read path).
    public func secureWipe() {
        lifecycle.secureWipe()
    }

    // MARK: - Tokenizer

    public var tokenizer: (any TokenizerProvider)? {
        lifecycle.tokenizer
    }

    // MARK: - Initializers

    public nonisolated init() {
        self.lifecycle = ModelLifecycleCoordinator()
        self.generation = GenerationQueue()
        // Provider wiring happens lazily via ensureProviderWired() on first use,
        // since `self` is not available inside a nonisolated init.
        Self.scheduleToolSpillReap()
    }

    /// Creates the service with a pre-populated ``ToolRegistry``.
    ///
    /// Pass the registry when the host app has tools to expose on the model's
    /// next generation. The coordinator dispatches ``ToolCall`` events through
    /// the registry and threads ``ToolResult`` payloads back into the
    /// conversation before the next turn. See `GenerationConfig.tools` and
    /// `GenerationConfig.toolChoice` for per-request wire-level control, and
    /// `GenerationConfig.maxToolIterations` for the per-request loop cap.
    ///
    /// The tool approval gate defaults to ``AutoApproveGate`` — every tool
    /// call dispatches without prompting. Use
    /// ``init(toolRegistry:toolApprovalGate:)`` to install a custom gate
    /// (e.g. a UI-driven approval sheet).
    public nonisolated init(toolRegistry: ToolRegistry) {
        self.lifecycle = ModelLifecycleCoordinator()
        self.generation = GenerationQueue(toolRegistry: toolRegistry)
        Self.scheduleToolSpillReap()
    }

    /// Creates the service with a pre-populated ``ToolRegistry`` and a
    /// custom ``ToolApprovalGate``.
    ///
    /// The gate is consulted before every ``ToolCall`` is dispatched. When
    /// the gate returns ``ToolApprovalDecision/denied(reason:)`` the
    /// coordinator synthesises a ``ToolResult`` with
    /// ``ToolResult/ErrorKind/permissionDenied`` and continues the stream
    /// — generation is not cancelled.
    public nonisolated init(toolRegistry: ToolRegistry, toolApprovalGate: any ToolApprovalGate) {
        self.lifecycle = ModelLifecycleCoordinator()
        self.generation = GenerationQueue(
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate
        )
        Self.scheduleToolSpillReap()
    }

    /// The ``ToolRegistry`` this service dispatches through, or `nil` when
    /// tool calling was not configured at init time. Register additional
    /// tools by calling ``ToolRegistry/register(_:)`` on the returned
    /// instance; the coordinator re-reads the registry on every turn.
    public var toolRegistry: ToolRegistry? {
        generation.toolRegistry
    }

    /// Configure a session-aware handoff detector. The runtime sets this
    /// once the conversation surface has agents registered; the dispatch
    /// loop then intercepts synthetic `transfer_to_<agent>` tool calls
    /// (emitted as ``GenerationEvent/handoffRequested(_:)``) instead of
    /// routing them through the regular ``ToolRegistry``.
    ///
    /// `nil` (the default) preserves the legacy single-agent surface —
    /// every tool call goes through the registry exactly as before.
    public func setHandoffDetector(_ detector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?) {
        generation.handoffDetector = detector
    }

    /// Install a pre-tool-use hook that the dispatch loop calls before every
    /// tool call. The hook may sanitize the JSON arguments or block the
    /// dispatch; the runtime wires this via ``PreToolUseHookAdapter`` so the
    /// sanitize-only contract is enforced before the closure ever reaches
    /// the loop. `nil` removes any installed hook (legacy direct-dispatch).
    ///
    /// `package` visibility: this is an internal seam between Runtime's
    /// ``HookRegistry`` and the Inference layer. Hosts compose hooks via
    /// ``ConversationRuntime`` instead of calling this directly.
    package func setPreToolUseHook(
        _ hook: (@Sendable (_ toolName: String, _ arguments: String, _ sessionID: UUID?) async -> PreToolUseOutcome)?
    ) {
        generation.preToolUseHook = hook
    }

    #if DEBUG
    /// Debug-only init that pre-loads a backend, optionally alongside a
    /// ``ToolRegistry`` and ``ToolApprovalGate``. Used by tests to drive a
    /// mock backend, and by ``--uitesting`` launches in the example app so
    /// the approval sheet can be exercised deterministically against a
    /// ``ScriptedBackend``.
    ///
    /// When `toolRegistry` is `nil` (the default) the generation coordinator
    /// is constructed without tool-calling wired in — matching the behaviour
    /// every existing test suite relies on. Pass a non-nil registry to
    /// enable tool dispatch; `toolApprovalGate` then gates each call and
    /// defaults to ``AutoApproveGate`` so legacy callers see no change.
    public init(
        backend: any InferenceBackend,
        name: String = "Mock",
        modelName: String? = nil,
        toolRegistry: ToolRegistry? = nil,
        toolApprovalGate: any ToolApprovalGate = AutoApproveGate()
    ) {
        self.lifecycle = ModelLifecycleCoordinator(backend: backend, name: name, modelName: modelName)
        self.generation = GenerationQueue(
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate
        )
        wireGenerationContext()
        Self.scheduleToolSpillReap()
    }
    #endif

    /// Fire-and-forget detached sweep of stale tool-spill files, scheduled
    /// from every public `init`. Detached so it never blocks instantiation
    /// — disk IO on `~/Library/Caches` is otherwise fast but the OS can
    /// stall under pressure, and a chat client should never spin on that.
    private nonisolated static func scheduleToolSpillReap() {
        Task.detached(priority: .background) {
            ToolSpillReaper.cleanOldSpills()
        }
    }

    private nonisolated static func modelReadyTimeoutNanoseconds(
        maxPollCount: Int,
        pollIntervalNanoseconds: UInt64
    ) -> UInt64 {
        guard maxPollCount > 0, pollIntervalNanoseconds > 0 else { return 0 }
        let (timeout, overflow) = UInt64(maxPollCount).multipliedReportingOverflow(by: pollIntervalNanoseconds)
        return overflow ? UInt64.max : timeout
    }

    // MARK: - Fast-Backend Dispatch

    /// Dispatches a backend-level generation request through the optional
    /// ``fastBackend`` first, falling back to the primary backend on failure.
    ///
    /// Goose-style fast/primary routing for lightweight subtasks. Behaviour:
    ///
    /// - When ``fastBackend`` is set **and** `preferFast == true`: tries the
    ///   fast backend first. If `generate(...)` throws synchronously, logs a
    ///   warning and retries on the primary backend.
    /// - When ``fastBackend`` is `nil` **or** `preferFast == false`:
    ///   dispatches directly to the primary backend.
    ///
    /// Stream-internal errors (errors thrown into the returned
    /// ``GenerationStream``) are **not** intercepted — they surface to the
    /// caller. This matches Goose's coarse-grained "fall back if the call
    /// fails" semantic and keeps the helper a thin primitive.
    ///
    /// This is the low-level primitive. Higher-level subtask paths (e.g.
    /// future LLM-driven session naming or summarisation) can opt in by
    /// passing `preferFast: true`. Public chat generation continues to use
    /// the queued ``enqueue(messages:...)`` path against the primary backend
    /// only.
    ///
    /// - Parameters:
    ///   - prompt: Assembled prompt string passed verbatim to the chosen backend.
    ///   - systemPrompt: Optional system prompt forwarded to the backend.
    ///   - config: Sampling/generation configuration for the call.
    ///   - preferFast: When `true` and ``fastBackend`` is set, the fast backend
    ///     is tried first. Defaults to `true` since the helper exists for that
    ///     case.
    /// - Returns: A ``GenerationStream`` from whichever backend served the call.
    /// - Throws: The primary backend's error if the primary path also fails.
    public func runFastOrPrimary(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        preferFast: Bool = true
    ) throws -> GenerationStream {
        ensureProviderWired()

        if preferFast, let fast = fastBackend {
            do {
                return try fast.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config
                )
            } catch {
                Log.inference.warning(
                    "fast backend failed, falling back to primary: \(String(describing: error), privacy: .public)"
                )
                // Fall through to primary dispatch below.
            }
        }

        guard let primary = lifecycle.backend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        return try primary.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )
    }

    /// Ensures the generation coordinator has a reference to this service.
    ///
    /// Called lazily because `nonisolated init()` cannot access `self` as a
    /// `@MainActor`-isolated reference. All public entry points that touch the
    /// generation coordinator call this first.
    private func ensureProviderWired() {
        if !generation.hasBoundContext {
            wireGenerationContext()
        }
    }
}

@MainActor
private final class ModelLoadReadinessObserver {
    private weak var service: InferenceService?
    private let continuation: AsyncStream<ModelLoadReadinessState>.Continuation
    private var isCancelled = false
    private var lastState: ModelLoadReadinessState?

    init(
        service: InferenceService,
        continuation: AsyncStream<ModelLoadReadinessState>.Continuation
    ) {
        self.service = service
        self.continuation = continuation
    }

    func start() {
        emitAndTrack()
    }

    func cancel() {
        isCancelled = true
    }

    private func emitAndTrack() {
        guard !isCancelled else { return }
        guard let service else {
            continuation.finish()
            return
        }

        withObservationTracking {
            let state = service.modelLoadReadinessState
            if state != lastState {
                lastState = state
                continuation.yield(state)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.emitAndTrack()
            }
        }
    }
}

// MARK: - Backend Context Bridging

extension InferenceService {
    /// Bridge into ``GenerationQueue``'s closure-based context seam.
    ///
    /// Replaces the former ``GenerationContextProvider`` protocol conformance.
    /// Each closure reads through `lifecycle` so the queue always sees the
    /// current backend / template state — never a cached snapshot.
    fileprivate func wireGenerationContext() {
        generation.bindContext(
            currentBackend: { [weak self] in self?.lifecycle.backend },
            isBackendLoaded: { [weak self] in self?.lifecycle.isModelLoaded ?? false },
            selectedPromptTemplate: { [weak self] in self?.lifecycle.selectedPromptTemplate ?? .chatML }
        )
    }
}

// MARK: - Backend Snapshot

extension InferenceService {
    public func registeredBackendSnapshot() -> EnabledBackends {
        lifecycle.registeredBackendSnapshot()
    }
}

// MARK: - Memory Pressure Events

extension InferenceService {

    /// A stream of memory-pressure and model-lifecycle events for this service.
    ///
    /// Multiple subscribers are supported; each receives an independent copy of
    /// every event broadcast after the stream is created. Events are buffered up
    /// to 64 entries per subscriber (newest-only once the buffer is full) so
    /// slow consumers don't stall the broadcaster.
    ///
    /// ```swift
    /// Task {
    ///     for await event in inferenceService.memoryPressureEvents() {
    ///         switch event {
    ///         case .levelChanged(let level):
    ///             updateMemoryIndicator(level)
    ///         case .willUnload(let id, let reason):
    ///             print("Model \(id) will unload: \(reason)")
    ///         case .didUnload(let id, _):
    ///             showReloadBanner()
    ///         case .didReload(let id):
    ///             hideReloadBanner()
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: An ``AsyncStream`` that yields ``MemoryPressureEvent`` values
    ///   until the service is deallocated or the subscriber cancels iteration.
    public func memoryPressureEvents() -> AsyncStream<MemoryPressureEvent> {
        pressureBroadcaster.makeStream()
    }

    /// Notifies the service of an OS memory-pressure level change so a
    /// ``MemoryPressureEvent/levelChanged(_:)`` event is emitted on all subscribers.
    ///
    /// Call this from the memory-pressure monitoring integration point (e.g.,
    /// ``ChatViewModel/handleMemoryPressure()``) after the OS fires a notification.
    /// This keeps `InferenceService` decoupled from the OS notification source while
    /// letting subscribers observe level transitions without polling.
    ///
    /// Package-visible — `ManifoldUI` wires this from ``ChatViewModel``; host apps
    /// that drive their own pressure monitoring should call
    /// ``InferenceService/memoryPressureEvents()`` and ``ChatViewModel/handleMemoryPressure()``
    /// rather than calling this directly.
    package func notifyPressureLevel(_ level: MemoryPressureLevel) {
        pressureBroadcaster.send(.levelChanged(level))
    }
}

// MARK: - ModelTypeCompatibilityProvider Conformance

extension InferenceService: ModelTypeCompatibilityProvider {

    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        lifecycle.compatibility(for: modelType)
    }

    public func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        lifecycle.compatibility(for: provider)
    }
}
