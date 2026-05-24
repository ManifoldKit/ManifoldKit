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

    /// The sink that receives an ``InferenceMetric`` after every generation call.
    ///
    /// Defaults to ``InMemoryMetricSink/shared`` so callers can read recent
    /// metrics without any configuration. Set to `nil` to disable metric emission.
    public var metricSink: (any InferenceMetricSink)? = InMemoryMetricSink.shared

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
    /// this duration, the stream throws ``CloudBackendError/timeout(_:)``.
    /// `nil` disables idle detection (default).
    public var streamIdleTimeout: Duration?

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
    /// returned events and injects ``GenerationEvent/thinkingComplete``
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
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard withStateLock({ _isModelLoaded && _baseURL != nil }) else {
            throw CloudBackendError.invalidURL("Backend not configured. Call loadModel first.")
        }

        try validateGenerationConfig(config)

        // Adapter-routed path: delegate request building to the routing's
        // closure. Legacy path: subclass override of `buildRequest`.
        let routingSnapshot = withStateLock { _adapterRouting }
        let request: URLRequest
        if let routing = routingSnapshot {
            request = try routing.buildRequest(prompt, systemPrompt, config)
        } else {
            request = try buildRequest(
                prompt: prompt,
                systemPrompt: systemPrompt,
                config: config
            )
        }

        let genID = withStateLock {
            _generationID += 1
            _isGenerating = true
            _lastUsage = nil
            return _generationID
        }

        let eventIDTracker = SSEEventIDTracker()
        withStateLock { _activeEventIDTracker = eventIDTracker }

        let capturedStrategy = retryStrategy
        let capturedSleeper = retrySleeper
        let session = self.urlSession
        let capturedTimeout = streamIdleTimeout
        let capturedBaseURL = baseURL
        let capturedMetricSink = metricSink
        let capturedModelName = modelName
        let capturedBackendName = backendName

        // The Task needs to set phases on the GenerationStream, but GenerationStream
        // wraps the stream (chicken-and-egg). Use a WeakBox that the Task captures;
        // we assign the real GenerationStream after creation.
        let streamBox = WeakBox<GenerationStream>(nil)
        let retryCounter = SendableCounter()
        let maxRetries = (capturedStrategy as? ExponentialBackoffStrategy)?.maxRetries ?? 3
        let weakSelf = WeakBox(self)

        // Tracks per-token timestamps for TTFT and inter-token latency.
        // Populated via the metric-observing wrapper stream below.
        let metricTracker = GenerationMetricTracker()

        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: CloudBackendError.backendDeallocated)
                return
            }

            let task = Task { [weak self] in
                defer {
                    self?.withStateLock {
                        if self?._generationID == genID {
                            self?._isGenerating = false
                            self?._activeEventIDTracker = nil
                        }
                    }
                }

                var streamError: Error?
                do {
                    // DNS rebinding guard: verify the endpoint's hostname does not
                    // resolve to a private/reserved address before connecting.
                    // Runs outside the retry block — a blocked address is not retryable.
                    if let url = capturedBaseURL {
                        try await DNSRebindingGuard.validate(url: url)
                    }

                    // Retry wraps only the HTTP connection phase — not SSE parsing.
                    // Mid-stream failures propagate immediately, preserving
                    // already-yielded tokens.
                    let (bytes, _) = try await withRetry(
                        strategy: capturedStrategy,
                        sleeper: capturedSleeper ?? { try await Task.sleep(for: $0) }
                    ) {
                        let attempt = retryCounter.incrementAndGet()
                        if attempt > 1 {
                            await MainActor.run { streamBox.value?.setPhase(.retrying(attempt: attempt - 1, of: maxRetries)) }
                        }

                        var attemptRequest = request
                        if let lastID = eventIDTracker.lastEventID {
                            attemptRequest.setValue(lastID, forHTTPHeaderField: "Last-Event-ID")
                        }
                        let (bytes, response) = try await session.bytes(for: attemptRequest)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            // Carry the rim's `serverError(statusCode: 0, ...)`
                            // shape so the eventual user-facing string is the
                            // unified "Server returned an unexpected response."
                            throw CloudBackendError.networkError(
                                underlying: ManifoldKitError.serverError(
                                    statusCode: 0,
                                    message: "Malformed server response"
                                )
                            )
                        }

                        try await weakSelf.value?.checkStatusCode(httpResponse, bytes: bytes)
                        return (bytes, httpResponse)
                    }

                    await MainActor.run { streamBox.value?.setPhase(.streaming) }

                    // Stream parsing — outside retry scope.
                    guard let self else {
                        throw CloudBackendError.backendDeallocated
                    }
                    try await self.parseResponseStream(bytes: bytes, config: config, continuation: continuation)

                    await MainActor.run { streamBox.value?.setPhase(.done) }
                    continuation.finish()
                } catch {
                    streamError = error
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        Log.network.error("\(self?.backendName ?? "SSECloud") stream error: \(error.localizedDescription, privacy: .private)")
                        await MainActor.run { streamBox.value?.setPhase(.failed(error.localizedDescription)) }
                        continuation.finish(throwing: error)
                    }
                }

                // Emit metric regardless of outcome so the sink receives both
                // successful and failed calls.
                if let sink = capturedMetricSink {
                    // `self` is weak here. If the backend was deallocated while the
                    // stream was in-flight, `lastUsage` is unavailable and we emit a
                    // metric with zero token counts. This is intentional — the metric
                    // still records timing and the error class, so cost analysis
                    // is the only field degraded.
                    let usage = self?.lastUsage
                    let promptTokens = usage?.promptTokens ?? 0
                    let completionTokens = usage?.completionTokens ?? 0
                    let (costUSD, isApprox) = InferenceCostEstimator.estimatedCost(
                        provider: capturedBackendName,
                        model: capturedModelName,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
                    )
                    let errorClass = streamError.map { Self.classifyError($0) }
                    let metric = metricTracker.buildMetric(
                        provider: capturedBackendName,
                        model: capturedModelName,
                        promptTokens: promptTokens,
                        cachedPromptTokens: 0,
                        completionTokens: completionTokens,
                        estimatedCostUSD: costUSD,
                        isCostApproximate: isApprox,
                        costTableDate: InferenceCostEstimator.costTableDate,
                        errorClass: errorClass
                    )
                    Task { await sink.record(metric) }
                }
            }

            self.withStateLock { self.currentTask = task }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        // Wrap the raw event stream in a metric-observing layer. Token events
        // are intercepted to record TTFT and inter-token latency as the consumer
        // iterates; the tracker is populated before the metric-emission Task
        // reads it on stream completion. Cancellation propagates inward via
        // structured-concurrency child task cancellation.
        let trackedStream: AsyncThrowingStream<GenerationEvent, Error>
        if capturedMetricSink != nil {
            trackedStream = AsyncThrowingStream { outerContinuation in
                let relayTask = Task {
                    metricTracker.start()
                    do {
                        for try await event in stream {
                            if case .token = event { metricTracker.recordToken() }
                            outerContinuation.yield(event)
                        }
                        outerContinuation.finish()
                    } catch {
                        outerContinuation.finish(throwing: error)
                    }
                }
                outerContinuation.onTermination = { @Sendable _ in
                    relayTask.cancel()
                }
            }
        } else {
            trackedStream = stream
        }

        let generationStream = GenerationStream(trackedStream, idleTimeout: capturedTimeout)
        streamBox.value = generationStream
        return generationStream
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
            try await parseResponseStreamRouted(
                routing: routing,
                bytes: bytes,
                continuation: continuation
            )
            return
        }
        try await parseResponseStream(bytes: bytes, continuation: continuation)
    }

    /// Adapter-routed stream loop. Drives the routing's
    /// ``CloudAdapterRouting/framedTransport`` to split bytes into frames,
    /// consults ``CloudAdapterRouting/payloadHandler`` for token / usage /
    /// error extraction, and lets ``CloudAdapterRouting/streamFinalizer``
    /// declare termination + carry terminal usage / stop-reason metadata.
    ///
    /// Subclasses do not override this — they install a routing via
    /// ``configure(adapterRouting:)`` instead. The method is `private`
    /// because the public hook is `parseResponseStream(bytes:config:continuation:)`,
    /// which dispatches into here when a routing is configured.
    private func parseResponseStreamRouted(
        routing: CloudAdapterRouting,
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let handler = routing.payloadHandler
        let finalizer = routing.streamFinalizer
        let consumer = routing.streamConsumerFactory?()
        var wasThinking = false
        var threwMidStream: Error?

        // Apply the same DoS guards as the SSE-direct path
        // (`SSEStreamParser`). Without these the routed transport (e.g.
        // ``NDJSONTransport``) is bounded only by the transport's own
        // soft caps, which silently drop frames instead of throwing
        // ``SSEStreamError`` and ignore the backend's `sseStreamLimits`
        // override. Closes the Phase 3/Ollama regression where Ollama
        // stopped honouring `streamTooLarge` / `eventTooLarge` /
        // `eventRateExceeded`.
        let limits = effectiveSSEStreamLimits
        var routedTotalBytes = 0
        var routedRateWindowStart = ContinuousClock.now
        var routedRateWindowCount = 0
        func routedNoteEventYielded() -> SSEStreamError? {
            let now = ContinuousClock.now
            if now - routedRateWindowStart >= .seconds(1) {
                routedRateWindowStart = now
                routedRateWindowCount = 1
                return nil
            }
            routedRateWindowCount += 1
            if routedRateWindowCount > limits.maxEventsPerSecond {
                return .eventRateExceeded(routedRateWindowCount)
            }
            return nil
        }

        do {
            for await frame in routing.framedTransport.frames(from: bytes) {
                if Task.isCancelled { break }

                // Single-frame cap. Mirror SSEStreamError.eventTooLarge so
                // the existing backend tests + retry UI keep working.
                if frame.count > limits.maxEventBytes {
                    throw SSEStreamError.eventTooLarge(frame.count)
                }
                // Cumulative cap. `+ 1` accounts for the newline framing
                // that NDJSON / SSE strip before the frame reaches us, so
                // the on-the-wire byte count closely matches what the
                // direct SSE path would see.
                routedTotalBytes += frame.count + 1
                if routedTotalBytes > limits.maxTotalBytes {
                    throw SSEStreamError.streamTooLarge(routedTotalBytes)
                }

                // Decode the frame as UTF-8 for the payload handler API, which
                // operates on `String`. `FramedTransport` ships `Data` so binary
                // bytes survive transport intact; the handler chooses how to
                // interpret. Empty / non-UTF-8 frames skip event extraction
                // but still get inspected by the finalizer below in case the
                // termination signal is binary.
                let payload = String(data: frame, encoding: .utf8) ?? ""

                if !payload.isEmpty {
                    if let consumer {
                        // Consumer-driven path: the consumer owns the full
                        // event vocabulary (tokens, reasoning handoff, tool
                        // calls, usage, prefill progress, finish-reason
                        // drains). The envelope only forwards what the
                        // consumer emits and still consults the handler for
                        // in-stream errors + the finalizer/isStreamEnd
                        // termination signals.
                        //
                        // Re-check `Task.isCancelled` between yields so a
                        // host cancel observed after the first event from a
                        // multi-event payload (e.g. a single Ollama NDJSON
                        // line carrying many `tool_calls[]` entries plus
                        // a thinking + content field) suppresses the
                        // remaining events on the same line. Mirrors the
                        // per-yield cancellation contract the legacy
                        // `OllamaStreamProcessor` implemented inline.
                        for event in consumer.consume(payload: payload) {
                            if Task.isCancelled { break }
                            // Mirror the usage event back into envelope
                            // bookkeeping so `lastUsage` stays accurate for
                            // hosts that read it post-stream.
                            if case .usage(let prompt, let completion) = event {
                                handleUsage((promptTokens: prompt, completionTokens: completion))
                            }
                            if let rateError = routedNoteEventYielded() {
                                throw rateError
                            }
                            continuation.yield(event)
                        }
                    } else {
                        for event in handler.extractEvents(from: payload) {
                            switch event {
                            case .thinkingToken:
                                wasThinking = true
                                continuation.yield(event)
                            case .thinkingComplete:
                                wasThinking = false
                                continuation.yield(event)
                            case .token:
                                if wasThinking {
                                    continuation.yield(.thinkingComplete)
                                    wasThinking = false
                                }
                                continuation.yield(event)
                            default:
                                continuation.yield(event)
                            }
                        }

                        if let usage = handler.extractUsage(from: payload) {
                            handleUsage(usage)
                            if let prompt = usage.promptTokens,
                               let completion = usage.completionTokens {
                                continuation.yield(.usage(prompt: prompt, completion: completion))
                            }
                        }
                    }

                    if let error = handler.extractStreamError(from: payload) {
                        throw error
                    }
                }

                // Finalizer takes precedence over the handler's `isStreamEnd`
                // boolean — it's the richer signal (carries usage + stop
                // reason on the terminal frame).
                if case .streamComplete(let usage, _) = finalizer.finalize(frame: frame) {
                    // On the consumer-driven path the consumer has already
                    // emitted any payload-carried `.usage` event; the
                    // finalizer signal is only used to break the loop. On
                    // the legacy path the finalizer carries the canonical
                    // terminal usage payload (Claude's split counts), so we
                    // mirror it through `handleUsage` and yield once.
                    if consumer == nil,
                       let usage,
                       let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        handleUsage((promptTokens: prompt, completionTokens: completion))
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                    break
                }

                // Fall back to the handler's stream-end boolean for
                // backends whose finalizer isn't authoritative on every
                // frame (e.g. providers where the stop sentinel is the
                // SSE `[DONE]` marker rather than a JSON field).
                if !payload.isEmpty, handler.isStreamEnd(payload) {
                    break
                }
            }
        } catch {
            threwMidStream = error
        }

        // Flush the consumer regardless of how the loop exited. On natural
        // termination this yields any open `.thinkingComplete` and tool
        // calls upstream never accompanied with an explicit
        // `finish_reason` / `response.completed`. On cancellation /
        // mid-stream error we still flush thinking but suppress phantom
        // tool calls so the consumer doesn't synthesise events the model
        // never committed to. Reaching stream-end *without* a finalizer
        // signal (e.g. Responses provider truncated before
        // `response.completed`) is a natural termination — fall through
        // to the consumer's flush rather than treating it as cancellation.
        if let consumer {
            let cancelled = Task.isCancelled || threwMidStream != nil
            for event in consumer.finish(cancelled: cancelled) {
                continuation.yield(event)
            }
        }

        if let threwMidStream {
            throw threwMidStream
        }
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
        // text), we inject a single `.thinkingComplete` so downstream
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
                case .thinkingComplete:
                    // Handler emitted the boundary itself (e.g. an inline-
                    // tag backend using `ThinkingParser`). Clear the flag
                    // so we don't double-emit on the next `.token`.
                    wasThinking = false
                    continuation.yield(event)
                case .token:
                    if wasThinking {
                        continuation.yield(.thinkingComplete)
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
                    continuation.yield(.usage(prompt: prompt, completion: completion))
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
            var errorBody = ""
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break }
            }
            let extracted = extractErrorMessage(from: errorBody)
            // Raw body goes to os.Logger at .private so developers can still
            // diagnose upstream issues via the Console / log archives; it never
            // reaches the UI.
            Log.network.debug("\(self.backendName, privacy: .public) upstream error body: \(errorBody, privacy: .private)")
            let host = withStateLock { _baseURL?.host() }
            let message = CloudErrorSanitizer.sanitize(extracted, host: host)
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
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
            case .timeout:              return "timeout"
            default:                    return "cloudError"
            }
        }
        return String(describing: type(of: error))
    }
}

// MARK: - Sendable Helpers

/// Thread-safe counter for tracking retry attempts across @Sendable closures.
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new value (1-based).
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Sendable wrapper for a weak reference to a non-Sendable class.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

// MARK: - Metric Tracking Helpers

/// Accumulates per-token timing data for a single generation call.
///
/// Thread-safety via `NSLock` — the same pattern as `SendableCounter` in this
/// file. Updated from the generation Task (arbitrary thread); read after the
/// Task completes to build the final ``InferenceMetric``.
final class GenerationMetricTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var wallStart: ContinuousClock.Instant = ContinuousClock.now
    private var dispatchDate: Date = Date()
    private var firstTokenInstant: ContinuousClock.Instant?
    private var lastTokenInstant: ContinuousClock.Instant?
    private var interTokenGapsNs: [Int64] = []

    func start() {
        lock.lock()
        defer { lock.unlock() }
        wallStart = ContinuousClock.now
        // Capture a Date alongside ContinuousClock so InferenceMetric carries an
        // absolute timestamp for time-series storage and log correlation.
        dispatchDate = Date()
    }

    func recordToken() {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if firstTokenInstant == nil {
            firstTokenInstant = now
        } else if let last = lastTokenInstant {
            // Nanosecond precision is sufficient for display; avoid Duration
            // arithmetic inside the lock to keep it fast.
            let gapNs = Int64((now - last).components.attoseconds / 1_000_000_000)
            interTokenGapsNs.append(gapNs)
        }
        lastTokenInstant = now
    }

    func buildMetric(
        provider: String,
        model: String,
        promptTokens: Int,
        cachedPromptTokens: Int,
        completionTokens: Int,
        estimatedCostUSD: Double,
        isCostApproximate: Bool,
        costTableDate: String,
        errorClass: String?
    ) -> InferenceMetric {
        lock.lock()
        defer { lock.unlock() }
        let wallEnd = ContinuousClock.now
        let wallClock: Duration = wallStart <= wallEnd ? wallEnd - wallStart : .zero
        let capturedDate = dispatchDate

        let ttft: Duration
        if let first = firstTokenInstant {
            ttft = wallStart <= first ? first - wallStart : .zero
        } else {
            ttft = .zero
        }

        let meanITL: Duration
        if interTokenGapsNs.isEmpty {
            meanITL = .zero
        } else {
            let sumNs = interTokenGapsNs.reduce(Int64(0), +)
            let avgNs = sumNs / Int64(interTokenGapsNs.count)
            meanITL = .nanoseconds(avgNs)
        }

        return InferenceMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            timeToFirstToken: ttft,
            meanInterTokenLatency: meanITL,
            wallClockDuration: wallClock,
            estimatedCostUSD: estimatedCostUSD,
            isCostApproximate: isCostApproximate,
            costTableDate: costTableDate,
            errorClass: errorClass,
            timestamp: capturedDate
        )
    }
}

