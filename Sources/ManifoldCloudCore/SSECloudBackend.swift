import Foundation
import os
import ManifoldInference

/// Base class for cloud inference backends that stream responses via Server-Sent Events.
///
/// Centralises the stream lifecycle, task management, exponential backoff retry,
/// framing, and thread-safe state management that OpenAI, Claude, OpenAI
/// Responses, and Ollama backends share.
///
/// ### Dual-path behavior
///
/// `SSECloudBackend` supports two routing modes:
///
/// 1. **Legacy path** (no adapter routing configured): concrete subclasses
///    override `buildRequest`, `parseResponseStream`, `extractErrorMessage`
///    and the base class wires `SSEStreamParser` directly. The subclass-
///    injected ``payloadHandler`` (set at init) drives event extraction.
///    All shipping backends are on this path today.
///
/// 2. **Adapter-routed path** (``adapterRouting`` configured via
///    ``configure(adapterRouting:)``): the envelope delegates
///    request building to ``CloudAdapterRouting/buildRequest``, framing to
///    ``CloudAdapterRouting/framedTransport``, event extraction to the
///    routing's ``CloudAdapterRouting/payloadHandler``, stream finalization
///    to ``CloudAdapterRouting/streamFinalizer``, and error-body decoding
///    to ``CloudAdapterRouting/errorBodyDecoder``. Subclasses become thin
///    hosts that compose an adapter, project it into a routing, and stop
///    branching on the provider.
///
/// The two paths coexist by design — Phase 2/B widens the envelope; later
/// phases migrate each backend onto the new path one PR at a time. The
/// legacy hooks (`buildRequest`, `parseResponseStream`, etc.) remain on
/// the class for source compatibility.
///
/// ### Concurrency
///
/// Thread safety uses `NSLock` (via ``withStateLock(_:)``) rather than
/// `@unchecked Sendable` on each subclass individually. The
/// `@unchecked Sendable` here is an *envelope* guarantee: the base class
/// serialises access to mutable state under the state lock. Adapters
/// composed into this envelope must not propagate the unchecked label —
/// they are value types and Sendable by virtue of their stored witnesses.
open class SSECloudBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {

    // MARK: - Lock

    private let stateLock = NSLock()

    /// Executes a closure while holding the state lock.
    @discardableResult
    public func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - State

    private var _isModelLoaded = false
    public var isModelLoaded: Bool {
        withStateLock { _isModelLoaded }
    }

    private var _isGenerating = false
    public var isGenerating: Bool {
        withStateLock { _isGenerating }
    }

    private var _baseURL: URL?
    /// The configured API base URL.
    public var baseURL: URL? {
        get { withStateLock { _baseURL } }
        set { withStateLock { _baseURL = newValue } }
    }

    private var _modelName: String
    /// The configured model identifier.
    public var modelName: String {
        get { withStateLock { _modelName } }
        set { withStateLock { _modelName = newValue } }
    }

    private var _keychainAccount: String?
    /// Keychain account identifier for just-in-time API key retrieval.
    public var keychainAccount: String? {
        get { withStateLock { _keychainAccount } }
        set { withStateLock { _keychainAccount = newValue } }
    }

    private var _tokenProvider: (any TokenProvider)?

    private var _ephemeralAPIKey: SecureBytes?
    /// Fallback API key for tests or ephemeral use. Prefer ``keychainAccount``.
    ///
    /// The backing store is a ``SecureBytes`` buffer that is zeroed with
    /// `memset_s` when the key is replaced or the backend is deallocated,
    /// limiting how long the raw key bytes survive in freed memory.
    ///
    /// > Warning: The `String` returned by the getter and any copies made while
    /// > building HTTP headers are *not* covered by this guarantee. For
    /// > production use prefer ``keychainAccount``-backed storage so the raw
    /// > key never enters the process heap at all.
    public var ephemeralAPIKey: String? {
        get { withStateLock { _ephemeralAPIKey?.stringValue } }
        set { withStateLock { _ephemeralAPIKey = newValue.flatMap { SecureBytes($0) } } }
    }

    private var _conversationHistory: [(role: String, content: String)]?
    /// Full conversation history for multi-turn support.
    public var conversationHistory: [(role: String, content: String)]? {
        get { withStateLock { _conversationHistory } }
        set { withStateLock { _conversationHistory = newValue } }
    }

    private var _lastUsage: (promptTokens: Int, completionTokens: Int)?
    /// Token usage from the most recent generation, if available.
    public var lastUsage: (promptTokens: Int, completionTokens: Int)? {
        get { withStateLock { _lastUsage } }
        set { withStateLock { _lastUsage = newValue } }
    }

    private var currentTask: Task<Void, Never>?
    private var _generationID: UInt64 = 0
    private var _activeEventIDTracker: SSEEventIDTracker?

    /// Per-request runtime hints for the in-flight generation (JSON mode,
    /// thinking markers, structured output). Split out of ``GenerationConfig``
    /// in #2152; because the cloud adapter indirection (`buildRequest` /
    /// `parseResponseStream`) is not on the `generate(...)` argument path, the
    /// active call's hints are stashed here under the state lock — mirroring the
    /// existing per-generation state (`_generationID`, `_lastUsage`). The queue
    /// serialises generation, so exactly one call's hints are live at a time.
    /// Subclasses read them via ``activeHints``.
    private var _activeHints = GenerationRuntimeHints()

    /// The in-flight generation's ``GenerationRuntimeHints``. Read by subclass
    /// `buildRequest` / `parseResponseStream` overrides that honour JSON mode,
    /// structured output, or thinking markers.
    public var activeHints: GenerationRuntimeHints {
        get { withStateLock { _activeHints } }
        set { withStateLock { _activeHints = newValue } }
    }

    /// The sink that receives an ``InferenceMetric`` after every generation call.
    ///
    /// Defaults to ``InMemoryMetricSink/shared`` so callers can read recent
    /// metrics without any configuration. Set to `nil` to disable metric emission.
    public var metricSink: (any InferenceMetricSink)? = InMemoryMetricSink.shared

    /// Optional vendor-neutral trace sink for OpenTelemetry-compatible span export.
    ///
    /// When set, each completed generation emits a ``GenSpan`` of kind ``SpanKind/llm``
    /// alongside the flat ``InferenceMetric``. Defaults to `nil` (no span export).
    /// Set to a ``RecordingTraceSink`` for tests or to your OTLP exporter in production.
    public var traceSink: (any TraceSink)?

    public let urlSession: URLSession

    /// SSE payload handler that extracts tokens, usage, stream-end signals,
    /// and errors from provider-specific JSON payloads.
    ///
    /// Injected at initialisation so the compiler enforces its presence — no
    /// runtime crash for forgotten overrides.
    ///
    /// > Note: When ``adapterRouting`` is configured, the adapter-routed
    /// > path uses ``CloudAdapterRouting/payloadHandler`` instead. This
    /// > property remains the legacy-path default so existing subclasses
    /// > continue to compile and run unchanged.
    public let payloadHandler: any SSEPayloadHandler

    private var _adapterRouting: CloudAdapterRouting?

    /// Adapter routing for backends composed via `CloudHTTPProviderAdapter`.
    ///
    /// When non-nil, ``generate(prompt:systemPrompt:config:)`` routes
    /// request building, framing, payload handling, stream finalization,
    /// and error-body decoding through the routing's witnesses instead of
    /// the legacy subclass-override path.
    ///
    /// Setter goes through the state lock so the value-type swap is
    /// observed atomically across the generation pipeline.
    public var adapterRouting: CloudAdapterRouting? {
        get { withStateLock { _adapterRouting } }
        set { withStateLock { _adapterRouting = newValue } }
    }

    /// The retry strategy used for HTTP connection failures. Defaults to
    /// ``ExponentialBackoffStrategy`` with standard settings. Inject a
    /// custom strategy for tests.
    public var retryStrategy: any RetryStrategy = ExponentialBackoffStrategy()

    /// Called to perform each retry delay. Defaults to `nil`, which uses `Task.sleep`
    /// (real wall clock). Inject a ``RecordingRetrySleeper`` in tests to assert delay
    /// bounds without real-time blocking.
    public var retrySleeper: (@Sendable (Duration) async throws -> Void)?

    /// Idle timeout for the generation stream. If no SSE event arrives within
    /// this duration, the stream throws ``InferenceError/idleTimeout(_:)``.
    /// `nil` disables idle detection (default).
    public var streamIdleTimeout: Duration?

    /// Per-request HTTP idle timeout, applied as `URLRequest.timeoutInterval`
    /// on every generation request.
    ///
    /// When non-nil, overrides the session-level `timeoutIntervalForRequest`
    /// from ``URLSessionProvider`` for each generation call. Use a generous
    /// value for LAN/local backends where the server may need time to load a
    /// model into VRAM before producing the first byte.
    ///
    /// `nil` (default) leaves `URLRequest.timeoutInterval` unset, so the
    /// session configuration's `timeoutIntervalForRequest` governs idle behavior.
    ///
    /// Distinct from ``streamIdleTimeout``, which is an application-level gate
    /// that fires when no SSE *event* arrives within a window after the
    /// connection is already open and streaming. This property controls the
    /// HTTP-layer idle window before the first byte.
    public var requestIdleTimeout: TimeInterval?

    /// Per-backend override for the SSE / NDJSON stream caps that defend
    /// against hostile upstream servers. When `nil` (default), the value
    /// from `ManifoldConfiguration.shared.sseStreamLimits` is used at
    /// parse time.
    ///
    /// Set this to tune limits for a specific backend — for example, to
    /// tighten bounds on an untrusted `CustomEndpoint` while leaving OpenAI
    /// and Anthropic at the global defaults.
    public var sseStreamLimits: SSEStreamLimits?

    /// Resolved stream limits, preferring the per-backend override and
    /// falling back to the global configuration.
    public var effectiveSSEStreamLimits: SSEStreamLimits {
        sseStreamLimits ?? ManifoldConfiguration.shared.sseStreamLimits
    }

    // MARK: - Init

    /// Creates an SSE cloud backend.
    ///
    /// - Parameters:
    ///   - defaultModelName: The default model identifier for this backend.
    ///   - urlSession: URLSession to use for network requests.
    ///   - payloadHandler: Interprets provider-specific SSE JSON payloads.
    ///     The compiler enforces this parameter, replacing the previous
    ///     runtime `fatalError` for missing `extractToken` / `buildRequest`
    ///     / `capabilities` overrides.
    public init(
        defaultModelName: String,
        urlSession: URLSession,
        payloadHandler: any SSEPayloadHandler
    ) {
        self._modelName = defaultModelName
        self.urlSession = urlSession
        self.payloadHandler = payloadHandler
    }

    // MARK: - Subclass Hooks

    /// Human-readable backend name for logging (e.g. "OpenAI", "Claude").
    open var backendName: String { "SSECloud" }

    /// Whether the stream should report ``GenerationStream/Phase/loading``
    /// during the pre-first-token window instead of jumping straight to
    /// ``GenerationStream/Phase/streaming`` once the HTTP connection succeeds.
    ///
    /// Cloud SaaS endpoints respond within milliseconds of connecting, so the
    /// base implementation returns `false` and the runner sets `.streaming`
    /// immediately after the headers arrive. LAN backends like Ollama can stall
    /// for minutes after `200 OK` while the server pulls the model into VRAM and
    /// prefills the prompt — the connection is open but no token has arrived. For
    /// those backends, override this to `true` so the phase reads `.loading`
    /// until the first event is yielded, then transitions to `.streaming`.
    open var signalsLoadingUntilFirstToken: Bool { false }

    /// The backend's capability declaration.
    ///
    /// Subclasses must override this property and return appropriate capabilities.
    /// The base implementation traps with a clear message — see `payloadHandler`
    /// for the recommended compile-time-enforced pattern.
    open var capabilities: BackendCapabilities {
        fatalError("\(type(of: self)) must override `capabilities`")
    }

    /// Optional ``ModelManifest`` describing the loaded model.
    ///
    /// Cloud subclasses derive this from a vendored prefix table
    /// (``CloudModelManifestTable``); LAN subclasses populate it from a
    /// runtime introspection probe (Ollama's `/api/show`). The base
    /// implementation returns `nil` — backends that haven't adopted the
    /// manifest source-of-truth pattern compile against this default.
    open var manifest: ModelManifest? { nil }

    /// Builds the URLRequest for a generation call.
    ///
    /// Called by ``generate(prompt:systemPrompt:config:)`` after validating state.
    /// Subclasses must override to produce the API-specific request format.
    open func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        fatalError("\(type(of: self)) must override `buildRequest(prompt:systemPrompt:config:)`")
    }

    /// Extracts a text token from an SSE JSON payload.
    ///
    /// The default implementation delegates to ``payloadHandler``.
    /// Subclasses may override for additional processing, but providing a
    /// custom ``SSEPayloadHandler`` at init is the preferred approach.
    ///
    /// - Important: Prefer ``extractEvents(from:)``. The shipping subclasses
    ///   (Ollama, Claude, OpenAI Chat Completions, OpenAI Responses) all
    ///   route per-payload classification through ``extractEvents(from:)``;
    ///   this hook stays for compatibility with external subclasses that
    ///   only override ``extractToken(from:)``.
    open func extractToken(from payload: String) -> String? {
        payloadHandler.extractToken(from: payload)
    }

    /// Maps an SSE JSON payload to zero or more generation events.
    ///
    /// The default implementation forwards to ``payloadHandler``'s
    /// ``SSEPayloadHandler/extractEvents(from:)``. The base
    /// ``parseResponseStream(bytes:continuation:)`` loop iterates the
    /// returned events and injects ``GenerationEvent/thinkingCompleted``
    /// on the first non-thinking-token event after one or more
    /// thinking-token events, so handlers stay stateless.
    open func extractEvents(from payload: String) -> [GenerationEvent] {
        payloadHandler.extractEvents(from: payload)
    }

    /// Extracts token usage from an SSE JSON payload.
    ///
    /// Return `nil` if the payload does not contain usage information.
    /// Either component can be `nil` for APIs that report usage in multiple events.
    open func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        payloadHandler.extractUsage(from: payload)
    }

    /// Returns `true` if the payload signals end of stream.
    ///
    /// The default implementation delegates to ``payloadHandler``.
    /// Override for APIs with explicit stop events (e.g. Claude's `message_stop`).
    open func isStreamEnd(_ payload: String) -> Bool {
        payloadHandler.isStreamEnd(payload)
    }

    /// Extracts an in-stream error from an SSE JSON payload.
    ///
    /// The default implementation delegates to ``payloadHandler``.
    /// Override for APIs that report errors as SSE events (e.g. Claude).
    open func extractStreamError(from payload: String) -> Error? {
        payloadHandler.extractStreamError(from: payload)
    }

    /// Called by ``generate(prompt:systemPrompt:config:)`` to update usage state.
    ///
    /// The default implementation sets ``lastUsage`` directly. Claude overrides
    /// this to merge split prompt/completion counts across multiple events.
    open func handleUsage(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        if let prompt = usage.promptTokens, let completion = usage.completionTokens {
            lastUsage = (promptTokens: prompt, completionTokens: completion)
        } else if let prompt = usage.promptTokens {
            lastUsage = (promptTokens: prompt, completionTokens: lastUsage?.completionTokens ?? 0)
        } else if let completion = usage.completionTokens {
            lastUsage = (promptTokens: lastUsage?.promptTokens ?? 0, completionTokens: completion)
        }
    }

    // MARK: - Shared Configuration

    /// Configures the backend with connection details.
    public func configure(baseURL: URL, apiKey: String?, modelName: String) {
        withStateLock {
            _baseURL = baseURL
            _ephemeralAPIKey = apiKey.flatMap { SecureBytes($0) }
            _keychainAccount = nil
            _modelName = modelName
        }
    }

    /// Configures the backend with a Keychain-backed API key.
    public func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        withStateLock {
            _baseURL = baseURL
            _keychainAccount = keychainAccount
            _ephemeralAPIKey = nil
            _modelName = modelName
        }
    }

    /// Configures the backend with a ``TokenProvider`` for rotating credentials.
    ///
    /// Use this overload for OAuth access tokens, JWTs, or any credential
    /// that may expire. The provider's ``TokenProvider/token()`` method is
    /// called on every outbound request via ``resolveTokenAsync()``.
    ///
    /// - Note: `buildRequest` is synchronous, so the ``TokenProvider`` path
    ///   requires callers to use ``resolveTokenAsync()`` in an async context
    ///   before building the request, rather than calling ``resolveAPIKeySecure()``
    ///   directly. Subclasses using a token provider should override
    ///   ``buildRequest(prompt:systemPrompt:config:)`` to accept an already-resolved
    ///   token, or adopt the adapter-routed path which supports async request building.
    public func configure(baseURL: URL, tokenProvider: any TokenProvider, modelName: String) {
        withStateLock {
            _baseURL = baseURL
            _tokenProvider = tokenProvider
            _ephemeralAPIKey = nil
            _keychainAccount = nil
            _modelName = modelName
        }
    }

    /// Configures the backend without an API key (for local servers).
    public func configure(baseURL: URL, modelName: String) {
        configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    }

    /// Installs adapter routing for the backend.
    ///
    /// After this call, ``generate(prompt:systemPrompt:config:)`` routes
    /// through the supplied routing's witnesses instead of the legacy
    /// subclass-override path. Pass `nil` to revert to the legacy path.
    public func configure(adapterRouting routing: CloudAdapterRouting?) {
        withStateLock { _adapterRouting = routing }
    }

    /// Retrieves the API key from Keychain or ephemeral storage.
    public func resolveAPIKey() -> String? {
        let (account, ephemeral) = withStateLock { (_keychainAccount, _ephemeralAPIKey?.stringValue) }
        if let account {
            return KeychainService.retrieve(account: account)
        }
        return ephemeral
    }

    /// Retrieves the API key as a zeroing ``SecureBytes`` buffer.
    ///
    /// On the Keychain path, this avoids allocating a transient Swift `String`
    /// by using ``KeychainService/retrieveSecure(account:)``, which copies the
    /// raw bytes directly into a ``SecureBytes`` buffer backed by `memset_s`
    /// zeroing on deallocation.
    ///
    /// On the ephemeral path, the long-lived ``SecureBytes`` held by
    /// ``_ephemeralAPIKey`` is buffer-copied into a fresh ``SecureBytes`` via
    /// ``SecureBytes/init(copying:)`` — no transient Swift `String` is
    /// materialized at any point, preserving the zeroing guarantee end-to-end.
    ///
    /// Returns `nil` when no key is configured.
    package func resolveAPIKeySecure() -> SecureBytes? {
        enum Plan {
            case keychain(String)
            case clone(SecureBytes)
            case none
        }
        // Snapshot the ephemeral SecureBytes reference (or keychain account)
        // under the lock. We retain the SecureBytes by reference rather than
        // reading its bytes here so the buffer copy happens outside the lock,
        // and we don't hold the lock across Keychain I/O.
        let plan: Plan = withStateLock {
            if let account = _keychainAccount { return .keychain(account) }
            if let source = _ephemeralAPIKey { return .clone(source) }
            return .none
        }
        switch plan {
        case .keychain(let account): return KeychainService.retrieveSecure(account: account)
        case .clone(let source):     return SecureBytes(copying: source)
        case .none:                  return nil
        }
    }

    /// Resolves the bearer token asynchronously.
    ///
    /// When a ``TokenProvider`` is configured, calls ``TokenProvider/token()``
    /// to obtain a (possibly freshly refreshed) token. Falls back to
    /// ``resolveAPIKeySecure()`` for Keychain-backed and ephemeral keys,
    /// returning the raw string value.
    ///
    /// Use this method in async contexts (e.g. adapter-routed request builders)
    /// instead of ``resolveAPIKeySecure()`` so that rotating-credential backends
    /// transparently refresh tokens without callers needing to know which
    /// credential source is configured.
    ///
    /// Returns `nil` when no credential of any kind is configured.
    package func resolveTokenAsync() async throws -> String? {
        if let provider = withStateLock({ _tokenProvider }) {
            return try await provider.token()
        }
        return resolveAPIKeySecure()?.stringValue
    }

    // MARK: - ConversationHistoryReceiver

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        withStateLock { _conversationHistory = messages }
    }

    // MARK: - Model Lifecycle

    /// Sets `isModelLoaded` to `true`.
    ///
    /// Subclasses override to add validation (e.g. checking API key existence)
    /// but should call `super.loadModel(from:plan:)` or set the flag directly.
    ///
    /// Plan is informational for cloud backends — the plan's
    /// `effectiveContextSize` is **not** propagated into any request payload
    /// (e.g. as `max_tokens`). Cloud providers enforce their own limits.
    open func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard withStateLock({ _baseURL }) != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:...) first."
            )
        }
        withStateLock { _isModelLoaded = true }
        Log.inference.info("\(self.backendName) backend loaded (model: \(self.modelName))")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        guard withStateLock({ _isModelLoaded && _baseURL != nil }) else {
            throw CloudBackendError.invalidURL("Backend not configured. Call loadModel first.")
        }

        // Stash the per-request hints so the adapter-indirected `buildRequest`
        // and `parseResponseStream` overrides can read them via `activeHints`.
        // Set before request building, which reads jsonMode / structuredOutput.
        withStateLock { _activeHints = hints }

        try validateGenerationConfig(config)

        let request = try makeGenerationRequest(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )
        let (genID, eventIDTracker) = beginGeneration()
        let taskContext = makeGenerationTaskContext(
            request: request,
            config: config,
            generationID: genID,
            eventIDTracker: eventIDTracker
        )

        // The Task needs to set phases on the GenerationStream, but GenerationStream
        // wraps the stream (chicken-and-egg). Use a WeakBox that the Task captures;
        // we assign the real GenerationStream after creation.
        let streamBox = WeakBox<GenerationStream>(nil)

        // Tracks per-token timestamps for TTFT and inter-token latency.
        // Populated via the metric-observing wrapper stream below.
        let metricTracker = GenerationMetricTracker()
        let stream = SSEGenerationTaskRunner(context: taskContext).makeRawStream(
            streamBox: streamBox,
            metricTracker: metricTracker
        )

        // Wrap the raw event stream in a metric-observing layer. Token events
        // are intercepted to record TTFT and inter-token latency as the consumer
        // iterates; the tracker is populated before the metric-emission Task
        // reads it on stream completion. Cancellation propagates inward via
        // structured-concurrency child task cancellation.
        let trackedStream = SSEGenerationMetrics.observing(
            stream,
            tracker: metricTracker,
            enabled: taskContext.metricSink != nil
        )

        let generationStream = GenerationStream(trackedStream, idleTimeout: taskContext.streamIdleTimeout)
        streamBox.value = generationStream
        return generationStream
    }

    private func makeGenerationRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        // Adapter-routed path: delegate request building to the routing's
        // closure. Legacy path: subclass override of `buildRequest`.
        if let routing = withStateLock({ _adapterRouting }) {
            return try routing.buildRequest(prompt, systemPrompt, config)
        }
        return try buildRequest(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )
    }

    private func beginGeneration() -> (generationID: UInt64, eventIDTracker: SSEEventIDTracker) {
        let generationID = withStateLock {
            _generationID += 1
            _isGenerating = true
            _lastUsage = nil
            return _generationID
        }

        let eventIDTracker = SSEEventIDTracker()
        withStateLock { _activeEventIDTracker = eventIDTracker }
        return (generationID, eventIDTracker)
    }

    private func makeGenerationTaskContext(
        request: URLRequest,
        config: GenerationConfig,
        generationID: UInt64,
        eventIDTracker: SSEEventIDTracker
    ) -> SSEGenerationTaskContext {
        var request = request
        if let timeout = requestIdleTimeout {
            request.timeoutInterval = timeout
        }
        let capturedStrategy = retryStrategy
        let capturedBaseURL = baseURL
        return SSEGenerationTaskContext(
            request: request,
            eventIDTracker: eventIDTracker,
            retryStrategy: capturedStrategy,
            retrySleeper: retrySleeper,
            session: urlSession,
            streamIdleTimeout: streamIdleTimeout,
            validateEndpoint: {
                if let url = capturedBaseURL {
                    try await DNSRebindingGuard.validate(url: url)
                }
            },
            metricSink: metricSink,
            traceSink: traceSink,
            modelName: modelName,
            backendName: backendName,
            maxRetries: (capturedStrategy as? ExponentialBackoffStrategy)?.maxRetries ?? 3,
            statusValidator: { [weak self] response, bytes in
                guard let self else {
                    throw CloudBackendError.backendDeallocated
                }
                try await self.checkStatusCode(response, bytes: bytes)
            },
            streamParser: { [weak self] bytes, continuation in
                guard let self else {
                    throw CloudBackendError.backendDeallocated
                }
                try await self.parseResponseStream(bytes: bytes, config: config, continuation: continuation)
            },
            readUsage: { [weak self] in
                self?.lastUsage
            },
            storeTask: { [weak self] task in
                guard let self else { return }
                self.withStateLock { self.currentTask = task }
            },
            finishGeneration: { [weak self] in
                guard let self else { return }
                self.withStateLock {
                    if self._generationID == generationID {
                        self._isGenerating = false
                        self._activeEventIDTracker = nil
                    }
                }
            },
            currentBackendName: { [weak self] in
                self?.backendName ?? "SSECloud"
            },
            signalsLoadingUntilFirstToken: signalsLoadingUntilFirstToken
        )
    }

    private func validateGenerationConfig(_ config: GenerationConfig) throws {
        if config.grammar != nil, !capabilities.supportsGrammarConstrainedSampling {
            throw InferenceError.unsupportedGrammar(
                reason: "\(backendName) does not support grammar-constrained sampling"
            )
        }
    }

    // MARK: - Stream Parsing

    /// Parses the HTTP response byte stream into generation events.
    ///
    /// The default implementation forwards to the config-less overload so
    /// existing subclasses (OpenAI, Claude) keep working unchanged. Subclasses
    /// that need the active ``GenerationConfig`` during parsing (e.g. Ollama
    /// needs ``GenerationConfig/maxThinkingTokens`` to cap reasoning output)
    /// override this method directly.
    open func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        if let routing = withStateLock({ _adapterRouting }) {
            let parser = CloudRoutedStreamParser(
                routing: routing,
                limits: effectiveSSEStreamLimits,
                handleUsage: { [self] usage in
                    handleUsage(usage)
                }
            )
            try await parser.parse(bytes: bytes, continuation: continuation)
            return
        }
        try await parseResponseStream(bytes: bytes, continuation: continuation)
    }

    /// Legacy overload retained for backward compatibility with subclasses
    /// that don't need access to the active ``GenerationConfig``.
    ///
    /// The default implementation uses SSE format via ``SSEStreamParser``.
    /// Subclasses override for NDJSON (Ollama) or other wire formats.
    open func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let tokenStream = SSEStreamParser.parse(
            bytes: bytes,
            limits: effectiveSSEStreamLimits,
            eventIDTracker: withStateLock { _activeEventIDTracker }
        )
        // Tracks whether the last emitted content event was a
        // `.thinkingToken`. When the next payload produces a `.token` (plain
        // text), we inject a single `.thinkingCompleted` so downstream
        // consumers see the reasoning block close exactly once, even for
        // field-based wire formats (Claude `thinking_delta`, OpenAI
        // `reasoning_content`) where the boundary is implicit.
        var wasThinking = false
        for try await payload in tokenStream {
            if Task.isCancelled { break }

            for event in extractEvents(from: payload) {
                switch event {
                case .thinkingToken:
                    wasThinking = true
                    continuation.yield(event)
                case .thinkingCompleted:
                    // Handler emitted the boundary itself (e.g. an inline-
                    // tag backend using `ThinkingTransform`). Clear the flag
                    // so we don't double-emit on the next `.token`.
                    wasThinking = false
                    continuation.yield(event)
                case .token:
                    if wasThinking {
                        continuation.yield(.thinkingCompleted)
                        wasThinking = false
                    }
                    continuation.yield(event)
                default:
                    continuation.yield(event)
                }
            }

            if let usage = extractUsage(from: payload) {
                handleUsage(usage)
                if let prompt = usage.promptTokens,
                   let completion = usage.completionTokens {
                    continuation.yield(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))
                }
            }

            if isStreamEnd(payload) {
                break
            }

            if let error = extractStreamError(from: payload) {
                throw error
            }
        }
    }

    // MARK: - Control

    public func stopGeneration() {
        withStateLock {
            currentTask?.cancel()
            currentTask = nil
            _isGenerating = false
        }
    }

    open func unloadModel() {
        stopGeneration()
        withStateLock {
            _baseURL = nil
            _keychainAccount = nil
            _ephemeralAPIKey = nil
            _tokenProvider = nil
            _isModelLoaded = false
        }
        Log.inference.info("\(self.backendName) backend unloaded")
    }

    // MARK: - HTTP Status Validation

    /// Checks the HTTP status code and throws an appropriate error for non-2xx responses.
    ///
    /// Handles 401/403 (auth), 429 (rate limit with Retry-After), and 5xx (server error
    /// with body extraction). Subclasses can override for provider-specific status handling.
    open func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode
        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 401, 403:
            throw CloudBackendError.authenticationFailed(provider: backendName)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            let message = await drainAndSanitizeErrorBody(bytes)
            throw CloudBackendError.sanitizedServerError(statusCode: statusCode, rawMessage: message)
        }
    }

    /// Maximum number of error-body bytes drained for diagnostics across all
    /// cloud backends. A few KB is plenty to capture a JSON error envelope
    /// while bounding memory if an upstream/proxy streams an unbounded body.
    /// Picked over the previous inconsistent 1000/2048 mix so every backend
    /// reports the same truncation behaviour.
    public static let errorBodyByteCap = 2048

    /// Drains a non-2xx response body, decodes it once as UTF-8, logs the raw
    /// body privately, and returns a sanitized, host-stripped error message
    /// suitable for surfacing in `CloudBackendError.serverError`.
    ///
    /// Shared by every subclass's `default:` status branch so the drain → cap →
    /// log → extract → sanitize sequence is implemented exactly once. Decoding
    /// is deferred until the full (capped) byte buffer is accumulated:
    /// appending one `UnicodeScalar` per byte would mangle any multi-byte
    /// UTF-8 sequence (non-ASCII upstream/proxy messages) into mojibake before
    /// the sanitizer ever sees it.
    ///
    /// - Parameters:
    ///   - bytes: the response byte stream (read up to ``errorBodyByteCap``).
    ///   - extractor: maps the decoded body to a human-readable message.
    ///     Defaults to ``extractErrorMessage(from:)`` (adapter-routing aware).
    /// - Returns: the sanitized message to surface to callers.
    package func drainAndSanitizeErrorBody(
        _ bytes: URLSession.AsyncBytes,
        extractor: ((String) -> String?)? = nil
    ) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.errorBodyByteCap { break }
            }
        } catch {
            // Best-effort — a partial body still aids diagnostics, but log the
            // interruption so the swallow stays observable.
            Log.network.debug("\(self.backendName, privacy: .public) error-body read interrupted: \(error.localizedDescription, privacy: .private)")
        }
        let errorBody = String(decoding: data, as: UTF8.self)
        // Raw body goes to os.Logger at .private so developers can still
        // diagnose upstream issues via the Console / log archives; it never
        // reaches the UI.
        Log.network.debug("\(self.backendName, privacy: .public) upstream error body: \(errorBody, privacy: .private)")
        let extracted = (extractor ?? extractErrorMessage(from:))(errorBody)
        let host = withStateLock { _baseURL?.host() }
        return CloudErrorSanitizer.sanitize(extracted, host: host)
    }

    /// Extracts an error message from a JSON error response body.
    ///
    /// The default implementation delegates to `parseCloudErrorMessage(from:)`, which
    /// handles the common `{"error":{"message":"..."}}` format used by OpenAI and Anthropic,
    /// as well as flat `{"message":"..."}` and `{"detail":"..."}` shapes.
    /// Subclasses can override for provider-specific formats.
    open func extractErrorMessage(from body: String) -> String? {
        if let decoder = withStateLock({ _adapterRouting?.errorBodyDecoder }) {
            return decoder.extractMessage(from: body)
        }
        return parseCloudErrorMessage(from: body)
    }

    // MARK: - State Mutation Helpers (for subclass use)

    /// Sets `isModelLoaded` under the state lock.
    public func setIsModelLoaded(_ value: Bool) {
        withStateLock { _isModelLoaded = value }
    }

    /// Sets `isGenerating` under the state lock.
    public func setIsGenerating(_ value: Bool) {
        withStateLock { _isGenerating = value }
    }

    // MARK: - Metric Helpers

    /// Returns a short identifier string for an error suitable for tagging metrics.
    ///
    /// Uses switch-on-type patterns over `CloudBackendError` cases so new cases
    /// get a descriptive label automatically. Falls back to the Swift type name
    /// for non-cloud errors so observers can distinguish network errors from
    /// parsing errors without having to decode the full message.
    static func classifyError(_ error: Error) -> String {
        if let cloud = error as? CloudBackendError {
            switch cloud {
            case .authenticationFailed: return "authenticationFailed"
            case .rateLimited:          return "rateLimited"
            case .serverError:          return "serverError"
            case .networkError:         return "networkError"
            case .invalidURL:           return "invalidURL"
            case .backendDeallocated:   return "backendDeallocated"
            default:                    return "cloudError"
            }
        }
        // The idle-timeout wrapper now throws the backend-neutral
        // `InferenceError.idleTimeout`, so classify it explicitly to preserve
        // the "timeout" metric tag.
        if case InferenceError.idleTimeout = error { return "timeout" }
        return String(describing: type(of: error))
    }
}
