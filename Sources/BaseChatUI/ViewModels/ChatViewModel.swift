import Foundation
import Observation
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference

/// Central view model for the chat interface.
///
/// Manages the message history, model lifecycle, generation settings, context
/// tracking, export, and SwiftData persistence. Views observe this via
/// `@Environment` and never call services directly.
///
/// ## Sharing InferenceService across components
///
/// `inferenceService` is intentionally `internal` — downstream apps should
/// create the service at the app level and inject it into all consumers:
///
/// ```swift
/// let inference = InferenceService()
/// let chatVM = ChatViewModel(inferenceService: inference)
/// let storyStore = StoryStore(inferenceService: inference)
/// ```
///
/// This keeps ChatViewModel's load coordination and state machine consistent.
/// Do not expose `inferenceService` publicly; if new consumers need generation
/// without lifecycle control, extract a focused protocol instead.
@Observable
@MainActor
public final class ChatViewModel {

    // MARK: - Services

    /// `package`-visible so views in `BaseChatUIModelManagement` (the peeled
    /// model-management surface) can read static capability queries off the
    /// service. Intentionally not `public` per CLAUDE.md — exposing the full
    /// `InferenceService` API on `ChatViewModel`'s public contract would lock
    /// in load-coordination internals. Hosts that need a shared service
    /// instance keep using the constructor-injection pattern documented there.
    package let inferenceService: InferenceService
    let deviceCapability: DeviceCapabilityService
    let modelStorage: ModelStorageService
    let memoryPressure: MemoryPressureHandler

    /// `UserDefaults` instance backing the first-run flag. Defaults to `.standard`
    /// in production. Tests inject a unique-per-instance suite so `swift test --parallel`
    /// runs cannot race on the shared `hasCompletedFirstLaunch` key.
    let userDefaults: UserDefaults

    /// The UI-layer ``ToolApprovalGate`` that drives the per-call approval
    /// sheet. When `nil`, the underlying ``InferenceService`` uses its
    /// default ``AutoApproveGate`` — every tool call dispatches silently.
    ///
    /// To wire an approval sheet, pass the same instance to both
    /// ``InferenceService/init(toolRegistry:toolApprovalGate:)`` and this
    /// view model's initializer. ``switchToSession(_:)`` forwards session
    /// resets so per-session approvals do not leak across chats.
    public let toolApprovalGate: UIToolApprovalGate?

    /// Convenience accessor for the gate's policy. Get returns
    /// ``UIToolApprovalGate/Policy/autoApprove`` when no gate was installed
    /// (the effective behaviour without a gate); set is a no-op in that case.
    public var toolApprovalPolicy: UIToolApprovalGate.Policy {
        get { toolApprovalGate?.policy ?? .autoApprove }
        set { toolApprovalGate?.policy = newValue }
    }

    /// Test-only seam: overrides the system-memory source used by `ModelLoadPlan`
    /// when deciding whether a local model load should proceed. Production code
    /// leaves this at `.current`; tests assign a deterministic environment.
    var loadPlanEnvironment: ModelLoadPlan.Environment = .current

    // MARK: - Persistence

    let sessionController: SessionController

    var persistence: (any SessionStore & MessageStore)? {
        get { sessionController.persistence }
        set { sessionController.persistence = newValue }
    }

    // MARK: - Session

    /// The currently active chat session. Set via `switchToSession(_:)`.
    public var activeSession: ChatSessionRecord? {
        get { sessionController.activeSession }
        set { sessionController.activeSession = newValue }
    }

    /// The session ID for the active session, or `nil` if no session is selected.
    var activeSessionID: UUID? { sessionController.activeSessionID }

    /// Called when a session might need its title auto-generated.
    /// Set by the view layer to connect to SessionManagerViewModel.
    public var onFirstMessage: (@MainActor (ChatSessionRecord, String) async -> Void)?

    // MARK: - First Run / Onboarding

    /// Called on the first launch instead of the default first-run behaviour.
    ///
    /// When set, this closure is invoked by `autoSelectFirstRunModel()` and the default
    /// Foundation model auto-selection is skipped entirely. If `nil`, the default
    /// behaviour auto-selects the Foundation model (if available); the model load itself
    /// is deferred to the view's `onChange(of: selectedModel)` handler to avoid a
    /// double-load race condition.
    public var onFirstLaunch: (@MainActor () -> Void)?

    /// Returns `true` if the Foundation model backend is available on this device.
    /// Apps should set this to enable Foundation model auto-discovery.
    /// Example: `chatViewModel.foundationModelProvider = { FoundationBackend.isAvailable }`
    public var foundationModelProvider: (@MainActor () -> Bool)?

    // MARK: - Published State

    /// All models discovered on disk plus the built-in Foundation model.
    public internal(set) var availableModels: [ModelInfo] = []

    /// Enabled cloud endpoints available for selection.
    public internal(set) var availableEndpoints: [APIEndpoint] = []

    /// The model the user has selected in the sidebar.
    public var selectedModel: ModelInfo? {
        didSet {
            guard !isSynchronizingSelection else { return }
            guard selectedModel != nil, selectedEndpoint != nil else { return }
            isSynchronizingSelection = true
            selectedEndpoint = nil
            isSynchronizingSelection = false
        }
    }

    /// The cloud API endpoint the user has selected, or `nil` for local models.
    /// Setting this clears `selectedModel` and vice versa.
    public var selectedEndpoint: APIEndpoint? {
        didSet {
            guard !isSynchronizingSelection else { return }
            guard selectedEndpoint != nil, selectedModel != nil else { return }
            isSynchronizingSelection = true
            selectedModel = nil
            isSynchronizingSelection = false
        }
    }

    /// Ordered messages for the active session.
    public internal(set) var messages: [ChatMessageRecord] {
        get { sessionController.messages }
        set { sessionController.messages = newValue }
    }

    /// The user's current input text.
    public var inputText: String = ""

    /// Rich parts staged in the compose bar but not yet sent.
    ///
    /// Today this is used for image attachments. The array stays typed as
    /// ``MessagePart`` so future compose-bar parts can reuse the same draft path.
    var draftAttachments: [MessagePart] = []

    /// Editable system prompt prepended to every generation.
    public var systemPrompt: String {
        get { sessionController.systemPrompt }
        set { sessionController.systemPrompt = newValue }
    }

    /// The current phase of backend activity, driving all status indicators.
    ///
    /// The setter is `internal(set)` for SwiftUI observation, but all production
    /// code paths must mutate this via ``transitionPhase(to:)`` so the
    /// ``ActivityPhaseStateMachine`` can validate the transition. Test-only
    /// direct writes bypass validation — see the state machine tests for
    /// exhaustive legal-transition coverage.
    public internal(set) var activityPhase: BackendActivityPhase = .idle {
        didSet {
            phaseMachine = ActivityPhaseStateMachine(phase: activityPhase)
            let wasGenerating = oldValue == .waitingForFirstToken || oldValue == .streaming
            let nowGenerating = activityPhase == .waitingForFirstToken || activityPhase == .streaming
            if wasGenerating != nowGenerating {
                onGeneratingChanged?(nowGenerating)
            }
            onActivityPhaseChanged?(activityPhase)
        }
    }

    /// Single source of truth for legal phase transitions. The view model
    /// never mutates `activityPhase` directly — every production code path
    /// routes through ``transitionPhase(to:)``.
    @ObservationIgnored
    private var phaseMachine = ActivityPhaseStateMachine(phase: .idle)

    /// Attempt to move to `newPhase`. Illegal transitions are logged and
    /// dropped — callers that know they may lose a race (stale progress
    /// callbacks, late stall notifications) rely on this to be a no-op.
    ///
    /// Returns `true` if the phase actually changed, `false` if the
    /// transition was rejected or was a same-phase no-op.
    @discardableResult
    func transitionPhase(to newPhase: BackendActivityPhase) -> Bool {
        let result = phaseMachine.transition(to: newPhase)
        switch result {
        case .applied:
            activityPhase = phaseMachine.phase
            return true
        case .unchanged:
            return false
        case .rejected(let from, let to):
            // Rejected transitions are a defence against bugs *and* a
            // defence against stale async events. We log at warning level
            // so CI surfaces unexpected bugs without crashing tests in
            // debug — per CLAUDE.md, `assertionFailure` is reserved for
            // conditions with no recovery path, and every rejection here
            // has an implicit recovery (ignore the event).
            Log.ui.warning(
                "ActivityPhaseStateMachine rejected transition: \(String(describing: from)) → \(String(describing: to))"
            )
            return false
        }
    }

    /// Whether a model is currently being loaded. Derived from `activityPhase`.
    public var isLoading: Bool {
        if case .modelLoading = activityPhase { return true }
        return false
    }

    /// Whether inference is currently streaming tokens. Derived from `activityPhase`.
    public var isGenerating: Bool {
        activityPhase == .waitingForFirstToken || activityPhase == .streaming
    }

    /// Test-only hook invoked whenever `isGenerating` changes.
    var onGeneratingChanged: ((Bool) -> Void)?

    /// Test-only hook invoked whenever `activityPhase` changes.
    var onActivityPhaseChanged: ((BackendActivityPhase) -> Void)?

    /// Structured error with recovery information for the UI.
    public var activeError: ChatError?

    /// Backward-compatible string accessor for error display.
    /// Returns the message from the active error, or nil if no error.
    public var errorMessage: String? {
        get { activeError?.message }
        set {
            if let message = newValue {
                activeError = ChatError(kind: .configuration, message: message, recovery: .dismissOnly)
            } else {
                activeError = nil
            }
        }
    }

    // MARK: - Post-Generation Tasks

    /// Background tasks to run after each generation completes, in registration order.
    ///
    /// Tasks run sequentially off `@MainActor`. A task that throws surfaces its
    /// error in ``backgroundTaskError`` but does not cancel subsequent tasks.
    /// All tasks are cancelled when the session is reset via ``switchToSession(_:)``.
    public var postGenerationTasks: [any PostGenerationTask] = []

    /// The most recent non-fatal error thrown by a post-generation background task.
    ///
    /// Surfaced for optional display by the app. Does not interrupt the session.
    public internal(set) var backgroundTaskError: Error?

    // MARK: - Pinned Messages

    /// IDs of messages that are pinned in the current session.
    ///
    /// Populated from ``ChatSessionRecord/pinnedMessageIDs`` when switching
    /// sessions. Persisted back to the session on changes.
    public internal(set) var pinnedMessageIDs: Set<UUID> {
        get { sessionController.pinnedMessageIDs }
        set { sessionController.pinnedMessageIDs = newValue }
    }

    // MARK: - Generation Settings

    public var temperature: Float {
        get { sessionController.temperature }
        set { sessionController.temperature = newValue }
    }
    public var topP: Float {
        get { sessionController.topP }
        set { sessionController.topP = newValue }
    }
    public var repeatPenalty: Float {
        get { sessionController.repeatPenalty }
        set { sessionController.repeatPenalty = newValue }
    }
    /// Cap on visible response tokens for each generation.
    ///
    /// Feeds two places:
    /// - The trim math in ``GenerationQueue`` reserves this many tokens
    ///   of the context window so the prompt is trimmed enough to leave room
    ///   for the response (see issue #587).
    /// - Forwarded to ``InferenceService/enqueue(...)`` as `maxOutputTokens`,
    ///   which backends enforce as their generation cap.
    ///
    /// Defaults to `2048`. Set `nil` to leave generation uncapped (the client
    /// trim math then falls back to the same `2048` reservation).
    public var maxOutputTokens: Int? = 2048

    /// Cap on reasoning tokens for each generation.
    ///
    /// Only reasoning-capable backends (MLX thinking models, Llama with thinking
    /// markers, Ollama with `think: true`) enforce this. `nil` means "no
    /// client-side cap" and reserves **zero** thinking tokens in the trim
    /// budget — set an explicit `N` when driving a reasoning model so the
    /// prompt is trimmed aggressively enough to leave room for the full
    /// advertised visible + thinking output. See issue #587.
    public var maxThinkingTokens: Int? = nil

    /// Minimum interval between batched UI updates during streaming (~30 fps by default).
    public var streamingUpdateInterval: Duration = .milliseconds(33)
    /// Maximum characters to buffer before forcing a UI flush during streaming.
    public var streamingBatchCharacterLimit: Int = 128

    /// Minimum interval between batched UI updates for streaming reasoning text.
    ///
    /// Decoupled from ``streamingUpdateInterval`` so apps can tune the visible-
    /// token cadence (which drives the primary message body) independently
    /// from reasoning preview cadence (which drives the small inline label
    /// inside the thinking disclosure group). Defaults match the visible-token
    /// batcher.
    public var thinkingStreamingUpdateInterval: Duration = .milliseconds(33)
    /// Maximum characters to buffer before forcing a UI flush for streaming reasoning text.
    public var thinkingStreamingBatchCharacterLimit: Int = 128

    /// Message IDs whose reasoning block is still being streamed.
    ///
    /// Populated when the first ``GenerationStreamConsumer/Action/appendThinkingText``
    /// fragment lands and cleared on ``GenerationStreamConsumer/Action/finalizeThinking``
    /// (or stream termination). Views read this to decide whether to render
    /// a partial-preview affordance versus the finalized disclosure group.
    /// Internal so views in the same module can read it without widening
    /// the public surface.
    var messageIDsWithStreamingThinking: Set<UUID> = []

    /// Whether to automatically stop generation when repetitive looping is detected.
    /// Defaults to `true`. Disable for apps that handle loop detection themselves.
    public var loopDetectionEnabled: Bool = true

    /// Simple key/value substitution for system prompt templates.
    ///
    /// Tokens written as `{{key}}` in the system prompt are replaced with the
    /// corresponding value in a single regex pass before the prompt reaches
    /// the backend. Intended for apps that want to inject a few strings (user
    /// name, persona, etc.) into a template without writing their own
    /// expansion layer.
    ///
    /// Behavior:
    /// - **Missing keys pass through.** A token whose key is not in the dict
    ///   is left in the prompt verbatim (e.g. `{{missing}}`), so callers can
    ///   spot typos by eye.
    /// - **All occurrences replaced.** Every occurrence of `{{key}}` in the
    ///   prompt is replaced, not just the first.
    /// - **Non-recursive.** If a value contains its own `{{token}}` pattern,
    ///   that nested token is left literal rather than re-substituted. E.g.,
    ///   setting `systemPromptContext["foo"] = "{{bar}}"` results in
    ///   `{{foo}}` expanding to the literal string `{{bar}}`, not recursively
    ///   into `{{bar}}`'s value. The single-pass scan also makes the result
    ///   independent of dictionary iteration order.
    /// - **Token pattern is `{{\w+}}`** — only alphanumeric and underscore
    ///   characters are recognized inside the braces. Anything else (spaces,
    ///   dots, empty `{{}}`) is ignored and passes through as literal text.
    public var systemPromptContext: [String: String] = [:]

    /// Prompt template for GGUF backends. Ignored by MLX/Foundation.
    public var selectedPromptTemplate: PromptTemplate {
        get { sessionController.selectedPromptTemplate }
        set {
            sessionController.selectedPromptTemplate = newValue
            inferenceService.selectedPromptTemplate = newValue
        }
    }

    // MARK: - Context Tracking

    /// Estimated tokens used by current messages + system prompt.
    public internal(set) var contextUsedTokens: Int = 0

    /// Maximum tokens for the current model/session configuration.
    public internal(set) var contextMaxTokens: Int = 2048

    /// Ratio of context used (0.0 to 1.0+).
    public var contextUsageRatio: Double {
        guard contextMaxTokens > 0 else { return 0 }
        return Double(contextUsedTokens) / Double(contextMaxTokens)
    }

    // MARK: - Computed Properties

    public var isModelLoaded: Bool {
        inferenceService.isModelLoaded
    }

    public var deviceDescription: String {
        deviceCapability.deviceDescription
    }

    public var recommendedSize: ModelSizeRecommendation {
        deviceCapability.recommendedModelSize()
    }

    public var modelsDirectoryPath: String {
        modelStorage.modelsDirectory.path
    }

    /// Capabilities of the active backend, or `nil` if none loaded.
    public var backendCapabilities: BackendCapabilities? {
        inferenceService.capabilities
    }

    var hasDraftContent: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
    }

    var supportsImageAttachments: Bool {
        backendCapabilities?.supportsVision == true
    }

    public var activeBackendName: String? {
        inferenceService.activeBackendName
    }

    public var activeModelName: String? {
        inferenceService.activeModelName
    }

    // MARK: - Onboarding

    /// `true` on the very first launch (before first-run logic runs).
    public internal(set) var isFirstRun: Bool

    /// Set to `true` after the first Foundation-backed assistant response completes
    /// in a session, suggesting the user download a local model for longer context.
    /// Apps can override this behaviour by replacing `onUpgradeHintTriggered`.
    public internal(set) var showUpgradeHint: Bool = false

    /// Called when the upgrade hint is first shown. Override to customise behaviour.
    /// Default is `nil` (no-op — the hint banner is displayed by `ChatView`).
    public var onUpgradeHintTriggered: (@MainActor () -> Void)?

    // MARK: - App Intents Bridge

    /// Receives ``ChatIntentAction`` values forwarded from the host app's
    /// App Intents bridge. Set by host apps that expose Siri / Spotlight
    /// integrations; left `nil` when no such bridge exists.
    ///
    /// `BaseChatUI` deliberately does not import `AppIntents` — the handler
    /// protocol defined in `BaseChatCore` keeps the seam framework-free.
    /// See ``ChatViewModel/dispatch(_:)`` for the forwarding entry point.
    public var intentHandler: (any ChatSessionIntentHandler)?

    // MARK: - Memory Indicator

    /// The current OS-level memory pressure level, forwarded from the handler.
    public var memoryPressureLevel: MemoryPressureLevel {
        memoryPressure.pressureLevel
    }

    /// Physical RAM of this device in bytes.
    public var physicalMemoryBytes: UInt64 {
        deviceCapability.physicalMemory
    }

    /// Current resident memory used by this process in bytes, sampled via Mach task info.
    ///
    /// Returns `nil` if the kernel call fails (should not happen in practice).
    public var appMemoryUsageBytes: UInt64? {
        AppMemoryUsage.currentBytes()
    }

    // MARK: - Load Coordinator

    /// Owns the "latest-wins with cancellation" model-load state machine.
    /// Extracted from `ChatViewModel` in phase 3 of #329.
    var loadCoordinator: ModelLoadCoordinator!

    /// Forwarding accessor so tests that mutate `vm.progressBridgePollInterval`
    /// continue to work without changes.
    var progressBridgePollInterval: Duration {
        get { loadCoordinator.progressBridgePollInterval }
        set { loadCoordinator.progressBridgePollInterval = newValue }
    }

    /// Forwarding accessor for completeness / test parity.
    var progressBridgeMinTransitionInterval: Duration {
        get { loadCoordinator.progressBridgeMinTransitionInterval }
        set { loadCoordinator.progressBridgeMinTransitionInterval = newValue }
    }

    // MARK: - ConversationRuntime

    /// The single turn-loop owner. ``sendMessage()``, ``regenerateLastResponse()``,
    /// ``editMessage(_:newContent:)``, and ``stopGeneration()`` all delegate to
    /// it; a long-lived event-drain task maps ``ConversationEvent`` values back
    /// to `@Observable` state on `@MainActor`.
    ///
    /// Constructor-injected and non-optional from the public API surface. Apps
    /// assembling shared services through ``BaseChatBootstrap`` get the
    /// bootstrap's runtime; tests and the convenience initializer get an
    /// in-memory runtime that's still functional for unit-test flows.
    ///
    /// `private(set)` (not `let`) because ``configure(persistence:)`` rebuilds
    /// the runtime against the newly-installed message store so tests and
    /// late-binding hosts that wire persistence after construction get a
    /// runtime backed by the configured storage. Hosts using
    /// ``BaseChatBootstrap`` should pass the bootstrap's runtime at
    /// construction and not rely on this rebuild path.
    private(set) var conversationRuntime: ConversationRuntime

    /// Drain task for the runtime event stream. Cancelled when the runtime
    /// is replaced or the view model is torn down.
    @ObservationIgnored
    private var runtimeEventDrainTask: Task<Void, Never>?

    /// `true` while the runtime is the default in-memory one created by the
    /// initializer (i.e. the host did not pass `conversationRuntime:` at
    /// construction). ``configure(persistence:)`` uses this flag to decide
    /// whether to rebuild the runtime against the newly-installed store —
    /// runtimes the host built explicitly are never replaced.
    @ObservationIgnored
    private var ownsDefaultRuntime: Bool = false

    /// Handle to the in-flight ConversationRuntime stream, used to cancel it.
    var activeConversationStreamHandle: ConversationStreamHandle?

    /// The assistant `messageID` carried by the most-recent `streamStarted`
    /// event. Used by ``ChatViewModel/handle(runtimeEvent:)`` to gate
    /// terminal events against the active turn — late events from a
    /// previously-cancelled turn (after `switchToSession`) carry a
    /// different messageID and must not clobber the new turn's handle.
    var activeConversationMessageID: UUID?

    // MARK: - Private State

    /// Token for the currently active generation request, if any.
    var activeGenerationToken: InferenceService.GenerationRequestToken?
    var generationTask: Task<Void, Never>?
    var backgroundTask: Task<Void, Never>?
    var lastPressureLevel: MemoryPressureLevel = .nominal
    private var isSynchronizingSelection = false
    var isRestoringSession = false

    /// Cached per-message token counts keyed by message ID, to avoid recalculating all messages.
    @ObservationIgnored
    var tokenCountCache: [UUID: Int] = [:]

    /// Reusable caching tokenizer that persists across generation cycles.
    /// Invalidated when the underlying backend tokenizer changes (i.e. model swap).
    @ObservationIgnored
    private var _cachingTokenizer: CachingTokenizer?
    /// Identity of the backend tokenizer the cached instance wraps, or `nil` when
    /// using the heuristic fallback. Used to detect model swaps.
    @ObservationIgnored
    private var _cachingTokenizerBaseID: ObjectIdentifier?

    /// Drops every per-message token cache entry and the reusable caching tokenizer.
    ///
    /// Called whenever the backend tokenizer identity may change out from under us
    /// (e.g. `unloadModel()`): message UUIDs are reused across sessions, so keeping
    /// counts from the previous model's tokenizer risks returning stale values in
    /// ``updateContextEstimate()`` after a later model swap.
    func invalidateTokenCaches() {
        tokenCountCache.removeAll()
        _cachingTokenizer = nil
        _cachingTokenizerBaseID = nil
    }

    #if DEBUG
    /// Test-only readback of the identity used to detect tokenizer changes in
    /// ``reusableCachingTokenizer``. Lets whitebox tests assert that the
    /// value-type / reference-type discriminator computes a stable ID per
    /// metatype — required to distinguish the correct implementation from the
    /// earlier `as? AnyObject` version, whose `_SwiftValue` boxing defeats any
    /// external behavioural probe.
    var _testOnly_cachingTokenizerBaseID: ObjectIdentifier? {
        _cachingTokenizerBaseID
    }
    #endif

    /// Returns a `CachingTokenizer` that persists across generation cycles,
    /// recreating it only when the underlying backend tokenizer changes.
    var reusableCachingTokenizer: CachingTokenizer {
        let backendTokenizer = inferenceService.tokenizer
        // Use ObjectIdentifier for reference-type tokenizers (e.g. LlamaBackend vends self),
        // fall back to type identity for value-type tokenizers (e.g. FoundationTokenizer).
        // `as? AnyObject` on a protocol existential always succeeds (values auto-box),
        // so discriminate on the metatype instead.
        let newBaseID: ObjectIdentifier? = backendTokenizer.map {
            if type(of: $0) is AnyClass {
                return ObjectIdentifier($0 as AnyObject)
            }
            return ObjectIdentifier(type(of: $0))
        }
        if let existing = _cachingTokenizer, _cachingTokenizerBaseID == newBaseID {
            return existing
        }
        let base: any TokenizerProvider = backendTokenizer ?? HeuristicTokenizer()
        let fresh = CachingTokenizer(wrapping: base)
        _cachingTokenizer = fresh
        _cachingTokenizerBaseID = newBaseID
        return fresh
    }

    /// Number of messages to load per page when paginating history.
    static let messagePageSize = SessionController.messagePageSize

    /// Whether older messages are available to load above the current page.
    public internal(set) var hasOlderMessages: Bool {
        get { sessionController.hasOlderMessages }
        set { sessionController.hasOlderMessages = newValue }
    }

    /// Whether a page of older messages is currently being fetched.
    public internal(set) var isLoadingOlderMessages: Bool {
        get { sessionController.isLoadingOlderMessages }
        set { sessionController.isLoadingOlderMessages = newValue }
    }

    // MARK: - Initialisation

    public convenience init(
        inferenceService: InferenceService = InferenceService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        toolApprovalGate: UIToolApprovalGate? = nil,
        userDefaults: UserDefaults = .standard,
        conversationRuntime: ConversationRuntime? = nil
    ) {
        self.init(
            inferenceService: inferenceService,
            deviceCapability: deviceCapability,
            modelStorage: modelStorage,
            memoryPressure: MemoryPressureHandler(),
            toolApprovalGate: toolApprovalGate,
            userDefaults: userDefaults,
            conversationRuntime: conversationRuntime
        )
    }

    package init(
        inferenceService: InferenceService = InferenceService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        memoryPressure: MemoryPressureHandler,
        toolApprovalGate: UIToolApprovalGate? = nil,
        userDefaults: UserDefaults = .standard,
        conversationRuntime: ConversationRuntime? = nil
    ) {
        self.inferenceService = inferenceService
        self.deviceCapability = deviceCapability
        self.modelStorage = modelStorage
        self.memoryPressure = memoryPressure
        self.toolApprovalGate = toolApprovalGate
        self.userDefaults = userDefaults
        self.sessionController = SessionController(selectedPromptTemplate: inferenceService.selectedPromptTemplate)
        // Non-optional runtime: callers assembling through `BaseChatBootstrap`
        // pass the shared instance; tests and ad-hoc construction get a
        // standalone runtime backed by an in-memory message store. Either way,
        // send/regenerate/edit/stop have a real turn loop to drive.
        let resolvedRuntime: ConversationRuntime
        if let conversationRuntime {
            resolvedRuntime = conversationRuntime
        } else {
            resolvedRuntime = ConversationRuntime(
                messageStore: InMemoryMessageStore(),
                inferenceService: inferenceService
            )
        }
        self.conversationRuntime = resolvedRuntime
        self.ownsDefaultRuntime = (conversationRuntime == nil)

        let firstRunKey = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        self.isFirstRun = !userDefaults.bool(forKey: firstRunKey)

        let coordinator = ModelLoadCoordinator(inferenceService: inferenceService)
        self.loadCoordinator = coordinator
        coordinator.onTransitionPhase = { [weak self] phase in
            self?.transitionPhase(to: phase) ?? false
        }
        coordinator.onSurfaceError = { [weak self] message in
            self?.errorMessage = message
        }
        coordinator.onClearError = { [weak self] in
            self?.errorMessage = nil
        }
        coordinator.onSetSelectedPromptTemplate = { [weak self] template in
            self?.selectedPromptTemplate = template
        }
        coordinator.onInvalidateTokenCaches = { [weak self] in
            self?.invalidateTokenCaches()
        }
        coordinator.isRestoringSession = { [weak self] in
            self?.isRestoringSession ?? false
        }
        coordinator.currentActivityPhase = { [weak self] in
            self?.activityPhase ?? .idle
        }
        coordinator.currentLoadPlanEnvironment = { [weak self] in
            self?.loadPlanEnvironment ?? .current
        }

        startRuntimeEventDrain()
    }

    /// Cancels the existing event drain (if any) and starts a fresh one for
    /// ``conversationRuntime``. Called from the initializer and from
    /// ``configure(persistence:)`` when the runtime is rebuilt.
    private func startRuntimeEventDrain() {
        runtimeEventDrainTask?.cancel()
        let runtime = conversationRuntime
        // `[weak self]` plus a per-iteration `guard let self` — hoisting the
        // `guard` outside the `for-await` upgrades `self` to strong for the
        // task's lifetime, which retains the view model until the runtime's
        // continuation finishes (i.e. forever in normal use). Re-checking
        // each iteration lets the view model deallocate between events.
        runtimeEventDrainTask = Task { [weak self] in
            for await event in runtime.events {
                guard let self else { return }
                await self.handle(runtimeEvent: event)
            }
        }
    }

    /// Injects the persistence stores. Call once after the storage backend is
    /// available, or prefer ``configure(runtime:)`` when bootstrapping through
    /// ``BaseChatRuntime``.
    ///
    /// Accepts a combined ``SessionStore`` + ``MessageStore`` existential —
    /// the SwiftData adapter conforms to both, and hosts that want to wire
    /// genuinely separate stores can pass a small composed adapter.
    ///
    /// When the view model still owns the default in-memory runtime created
    /// at construction (i.e. the host did not pass `conversationRuntime:`),
    /// this call rebuilds the runtime against the newly-installed message
    /// store so subsequent send/regenerate/edit calls persist through the
    /// configured storage. Hosts that constructed their own
    /// ``ConversationRuntime`` keep it — the runtime is the source of truth
    /// for message persistence and replacing it would silently shadow the
    /// host's setup.
    public func configure(persistence: any SessionStore & MessageStore) {
        sessionController.configure(persistence: persistence)
        if ownsDefaultRuntime {
            conversationRuntime = ConversationRuntime(
                messageStore: persistence,
                sessionStore: persistence,
                inferenceService: inferenceService
            )
            startRuntimeEventDrain()
        }
    }

    // MARK: - Structured Error Surfacing

    /// Surfaces an error with structured type information.
    func surfaceError(_ error: any Error, kind: ChatError.Kind, context: String? = nil) {
        activeError = ChatError.from(error, kind: kind, context: context)
    }
}
