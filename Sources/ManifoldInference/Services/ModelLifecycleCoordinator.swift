import Foundation
import ManifoldHardware
import Observation

/// Owns backend registration, model loading/unloading, the `LoadRequestToken`
/// lifecycle, progress reporting, deny-policy enforcement, and capability/compatibility queries.
///
/// This is an internal implementation detail of `ManifoldInference`.
/// `InferenceService` delegates all lifecycle operations to this coordinator
/// and preserves the unchanged public API.
@Observable
@MainActor
final class ModelLifecycleCoordinator {

    // MARK: - Published State

    private(set) var isModelLoaded = false
    private(set) var activeBackendName: String?
    private(set) var activeModelName: String?
    private(set) var modelLoadProgress: Double?

    /// Timestamp of the moment `isModelLoaded` transitioned to `true` for the
    /// current resident model. Cleared to `nil` on unload.
    private(set) var loadedAt: Date?

    /// Best-effort selection-time footprint estimate for the resident model, in
    /// bytes. Sourced from `ModelLoadPlan.outcome.totalEstimatedBytes` when a
    /// plan-based load is used. `nil` for cloud endpoints or when no plan was
    /// computed (e.g. the `#if DEBUG` test init path).
    private(set) var residentFootprintBytes: UInt64?

    /// Identity of the ``APIEndpointRecord`` backing the active endpoint
    /// backend, or `nil` for on-disk model loads (which have no endpoint
    /// record). Threaded through the load commit so usage accounting can
    /// attribute a turn to the endpoint that served it (#1207). Cleared on
    /// unload alongside the other active-backend metadata.
    private(set) var activeEndpointID: UUID?

    // MARK: - Backend

    private(set) var backend: (any InferenceBackend)?

    // MARK: - Deny Policy

    /// Policy applied when a ``ModelLoadPlan`` returns a `.deny` verdict.
    /// Mirrors the facade's `InferenceService.denyPolicy`; written by the facade's
    /// `didSet` so tests and custom gates can swap it before each load.
    var denyPolicy: LoadDenyPolicy = .platformDefault

    // MARK: - Keep-Alive Policy

    /// Policy that controls automatic idle unloading. Defaults to `.never` (disabled).
    ///
    /// When set to a non-nil `idleTimeout`, an idle watch task is armed after each
    /// successful model load. The task polls the generation queue's idle duration
    /// and calls the facade's `unloadModel(reason:)` with `.idleTimeout` when the
    /// model has been idle longer than the threshold.
    ///
    /// Written by the InferenceService facade's `didSet` so callers interact only
    /// with the public-facing property.
    var keepAlivePolicy: KeepAlivePolicy = .never {
        didSet { applyKeepAlivePolicy() }
    }

    /// Closure through which the idle watch task requests an unload on the facade.
    ///
    /// Injected by ``InferenceService`` after init (the coordinator cannot hold a
    /// strong reference to the service directly — that would create a retain cycle
    /// since the service owns the coordinator). The closure is `@Sendable` so the
    /// watch `Task { }` can capture it safely under Swift 6 strict concurrency.
    var unloadRequestHandler: (@MainActor @Sendable (UnloadReason) -> Void)?

    /// Closure that returns the current generation queue idle duration.
    ///
    /// Injected by ``InferenceService`` after init so the coordinator can poll
    /// idle time without holding a direct reference to the generation queue.
    var idleDurationProvider: (@MainActor @Sendable () -> TimeInterval)?

    /// The running idle watch task, if any. Cancelled when a model unloads or
    /// when `keepAlivePolicy` changes to `.never`.
    private var idleWatchTask: Task<Void, Never>?

    // MARK: - Prompt Template

    var selectedPromptTemplate: PromptTemplate = .chatML

    /// The active model's embedded Jinja chat-template string, captured from
    /// ``ModelInfo/chatTemplateRaw`` at load time, or `nil` for templateless
    /// models. When present and renderable, the generation queue renders the
    /// model's *real* template rather than approximating it with the detected
    /// ``selectedPromptTemplate`` enum case (#1811). Set on load, cleared on
    /// unload — never user-editable, so it always reflects the loaded GGUF.
    private(set) var selectedChatTemplateRaw: String?

    // MARK: - Backend Registry

    private var backendFactories: [BackendFactory] = []
    private var cloudBackendFactories: [EndpointBackendFactory] = []
    private var supportedLocalModelTypes: Set<ModelType> = []
    private var supportedCloudProviders: Set<APIProvider> = []

    // MARK: - Load Request Token State

    private struct LoadRequestToken: Hashable, Comparable, Sendable {
        let rawValue: UInt64
        static let zero = Self(rawValue: 0)
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum LoadPhase: Equatable {
        case idle
        case loading(request: LoadRequestToken)
        case loaded(request: LoadRequestToken)
    }

    private struct LoadRequestMetadata {
        let source: String
        let target: String
        let backend: String
        let startedAtUptime: TimeInterval
    }

    private var nextLoadRequestToken: LoadRequestToken = .zero
    private var latestRequestedLoadToken: LoadRequestToken?
    private var invalidatedThroughToken: LoadRequestToken = .zero
    private var loadPhase: LoadPhase = .idle
    private var loadRequestMetadataByToken: [LoadRequestToken: LoadRequestMetadata] = [:]

    // MARK: - Initializers

    nonisolated init() {}

    /// Seam for preloading a backend without driving the real load pipeline.
    ///
    /// Always available (previously `#if DEBUG`-gated): the offline tool-calling
    /// harness (`ManifoldTools.ScenarioRunner`) is a legitimate release consumer
    /// that injects a pre-built backend so its scenario runs mirror the live
    /// orchestration path. The body only sets stored fields — no test-only types.
    ///
    /// - Parameters:
    ///   - backend: the pre-configured backend to install as current.
    ///   - name: the backend engine label. Use ``BackendName/rawValue`` for the
    ///     six first-class backends (e.g. `BackendName.llama.rawValue` →
    ///     `"llama"`) so the value matches what the production load path emits.
    ///     Stored in ``activeBackendName`` and in request metadata as the
    ///     `backend` field.
    ///   - modelName: the human-readable model name (e.g. from `ModelInfo.name`).
    ///     Stored in ``activeModelName``. Defaults to `nil` when the test did not
    ///     load through the real pipeline and therefore has no model-level name.
    init(backend: any InferenceBackend, name: String = "Mock", modelName: String? = nil) {
        self.backend = backend
        self.isModelLoaded = true
        self.activeBackendName = name
        self.activeModelName = modelName
        self.loadedAt = Date()
        let request = LoadRequestToken(rawValue: 1)
        self.nextLoadRequestToken = request
        self.latestRequestedLoadToken = request
        self.loadPhase = .loaded(request: request)
        self.loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: "debug",
            target: modelName ?? name,
            backend: name,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: - Backend Registration

    func registerBackendFactory(_ factory: @escaping BackendFactory) {
        backendFactories.append(factory)
    }

    func registerEndpointBackendFactory(_ factory: @escaping EndpointBackendFactory) {
        cloudBackendFactories.append(factory)
    }

    func declareSupport(for modelType: ModelType) {
        supportedLocalModelTypes.insert(modelType)
    }

    func declareSupport(for provider: APIProvider) {
        supportedCloudProviders.insert(provider)
    }

    // MARK: - Model Loading

    func loadModel(
        from modelInfo: ModelInfo,
        contextSize: Int32 = 2048
    ) async throws {
        unloadModel()

        guard let newBackend = createBackend(for: modelInfo.modelType) else {
            throw InferenceError.inferenceFailure(
                "No registered backend can handle model type \(modelInfo.modelType). "
                + "This usually means the matching backend is unavailable on this OS or "
                + "build rather than unregistered: environment-gated types only resolve "
                + "when their prerequisites are met (e.g. .foundation requires macOS 26 / "
                + "iOS 26 with Apple Intelligence enabled; MLX and GGUF require their "
                + "backend packages to be linked and registered — manifold-mlx / "
                + "manifold-llama since the v0.48 split, see docs/MIGRATION-0.48.md). "
                + "If you genuinely have not registered a backend for this type, register "
                + "a BackendFactory (call DefaultBackends.register, or pass the companion "
                + "registrar to quickStart(backends:)) before loading models."
            )
        }

        // Legacy path: build a plan using the backend's declared memory strategy,
        // then delegate to the shared implementation. Sourcing the strategy from
        // the backend (rather than from `modelType`) preserves pre-plan behaviour
        // for callers that register backends with non-default strategies.
        let plan: ModelLoadPlan
        if newBackend.capabilities.memoryStrategy == .external {
            // `.external` backends own their own memory (Foundation Models / cloud);
            // the plan is always-allow.
            plan = ModelLoadPlan.systemManaged(requestedContextSize: Int(contextSize))
        } else {
            plan = ModelLoadPlan.compute(
                for: modelInfo,
                requestedContextSize: Int(contextSize),
                strategy: newBackend.capabilities.memoryStrategy,
                environment: .current
            )
        }
        try await performLoad(modelInfo: modelInfo, plan: plan, backend: newBackend)
    }

    func loadModel(
        from modelInfo: ModelInfo,
        plan: ModelLoadPlan
    ) async throws {
        unloadModel()

        guard let newBackend = createBackend(for: modelInfo.modelType) else {
            throw InferenceError.inferenceFailure(
                "No registered backend can handle model type \(modelInfo.modelType). "
                + "This usually means the matching backend is unavailable on this OS or "
                + "build rather than unregistered: environment-gated types only resolve "
                + "when their prerequisites are met (e.g. .foundation requires macOS 26 / "
                + "iOS 26 with Apple Intelligence enabled; MLX and GGUF require their "
                + "backend packages to be linked and registered — manifold-mlx / "
                + "manifold-llama since the v0.48 split, see docs/MIGRATION-0.48.md). "
                + "If you genuinely have not registered a backend for this type, register "
                + "a BackendFactory (call DefaultBackends.register, or pass the companion "
                + "registrar to quickStart(backends:)) before loading models."
            )
        }

        try await performLoad(modelInfo: modelInfo, plan: plan, backend: newBackend)
    }

    /// Shared implementation for the two `loadModel` overloads. Assumes the caller
    /// has already created the backend and built the plan.
    private func performLoad(
        modelInfo: ModelInfo,
        plan: ModelLoadPlan,
        backend newBackend: any InferenceBackend
    ) async throws {
        // Pre-flight memory check based on the plan's verdict. On `.deny`, apply
        // the coordinator's `denyPolicy` — the three-way `LoadDenyPolicy` exposes
        // the full plan to custom hooks.
        //
        // On `.deny` (when policy chooses to proceed) we downgrade the plan's
        // verdict to `.warn` before dispatching to the backend so the backend's
        // `plan.verdict != .deny` precondition holds.
        var effectivePlan = plan
        switch plan.verdict {
        case .allow:
            break
        case .warn:
            let estMB = plan.outcome.totalEstimatedBytes / 1_048_576
            let availMB = plan.inputs.availableMemoryBytes / 1_048_576
            Log.inference.warning("Memory warning (plan): needs ~\(estMB) MB, \(availMB) MB available")
        case .deny:
            let required = plan.outcome.totalEstimatedBytes
            let available = plan.inputs.availableMemoryBytes
            switch denyPolicy {
            case .throwError:
                throw InferenceError.memoryInsufficient(required: required, available: available)
            case .warnOnly:
                Log.inference.warning("Memory insufficient (plan): ~\(required / 1_048_576) MB needed, \(available / 1_048_576) MB available. Proceeding (may swap).")
                effectivePlan = downgradeDenyToWarn(plan)
            case .custom(let handler):
                // Handler chooses: throw to reject, return to proceed.
                try handler(plan)
                effectivePlan = downgradeDenyToWarn(plan)
            }
        }

        let backendName = backendDisplayName(for: modelInfo.modelType)
        let url = modelInfo.url
        let mmprojURL = modelInfo.mmprojURL
        let dispatchPlan = effectivePlan
        // Capture the plan's footprint estimate so `commitLoadIfCurrent` can
        // store it as `residentFootprintBytes`. Only non-zero estimates are
        // meaningful; zero is the plan's unset default for cloud/system-managed
        // backends and is stored as `nil` to signal "unknown".
        let footprint: UInt64? = plan.outcome.totalEstimatedBytes > 0
            ? plan.outcome.totalEstimatedBytes
            : nil
        // Capture the model's embedded Jinja chat template (if any) so the
        // generation queue can render the model's *real* template rather than
        // approximating it with the detected enum case (#1811). Local GGUF loads
        // are the only path that carries a ModelInfo; cloud/endpoint loads go
        // through `runLoad` directly and leave this nil (cloud backends do not
        // use prompt templates).
        selectedChatTemplateRaw = modelInfo.chatTemplateRaw
        try await runLoad(
            source: "local",
            target: modelTypeLogLabel(modelInfo.modelType),
            backendName: backendName,
            backend: newBackend,
            modelName: modelInfo.name,
            footprintBytes: footprint
        ) {
            (newBackend as? MultimodalProjectorConfigurable)?.setMmprojURL(mmprojURL)
            try await newBackend.loadModel(from: url, plan: dispatchPlan)
        }
    }

    /// Shared begin/install/detached-load/catch/commit ceremony for both the
    /// on-disk model path and the cloud-endpoint path. The only per-call
    /// variation is the request labels, the model name, and the detached load
    /// body — passed in as `loadOperation`, which runs off the main actor
    /// inside `Task.detached`.
    private func runLoad(
        source: String,
        target: String,
        backendName: String,
        backend newBackend: any InferenceBackend,
        modelName: String,
        endpointID: UUID? = nil,
        footprintBytes: UInt64? = nil,
        loadOperation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let request = beginLoadRequest(
            source: source,
            target: target,
            backend: backendName
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            try await Task.detached(priority: .userInitiated) {
                try await loadOperation()
            }.value
        } catch {
            (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)
            let isStale = finishLoadAttemptWithFailure(request, error: error)
            if isStale {
                newBackend.unloadModel()
            }
            throw error
        }
        (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)

        logLoadEvent("load.complete", request: request)
        guard commitLoadIfCurrent(
            request: request,
            backend: newBackend,
            backendName: backendName,
            modelName: modelName,
            endpointID: endpointID,
            footprintBytes: footprintBytes
        ) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    func loadEndpointBackend(from endpoint: APIEndpointRecord) async throws {
        // Validate before unloading the current model so a bad endpoint doesn't
        // leave the user with no backend at all.
        try endpoint.validate()

        unloadModel()

        // URL(string:) is guaranteed to succeed after validate(), but force-unwrap
        // is avoided here in case of future trimming divergence.
        guard let url = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CloudBackendError.invalidURL(endpoint.baseURL)
        }

        guard let newBackend = createCloudBackend(for: endpoint.provider) else {
            throw InferenceError.inferenceFailure(
                "No registered cloud backend factory can handle provider \(endpoint.provider.rawValue). "
                + "Register an EndpointBackendFactory before loading endpoint backends."
            )
        }

        switch endpoint.provider {
        case .claude, .openAI, .openAIResponses, .custom:
            guard let keychainConfigurable = newBackend as? EndpointBackendKeychainConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Endpoint backend \(type(of: newBackend)) must conform to EndpointBackendKeychainConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            keychainConfigurable.configure(
                baseURL: url,
                keychainAccount: endpoint.keychainAccount,
                modelName: endpoint.modelName
            )

        case .ollama, .lmStudio:
            guard let urlModelConfigurable = newBackend as? EndpointBackendURLModelConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Endpoint backend \(type(of: newBackend)) must conform to EndpointBackendURLModelConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            urlModelConfigurable.configure(baseURL: url, modelName: endpoint.modelName)
        }

        // Bridge MK's owned keep-alive policy into the backend's *advisory*
        // (server-side) residency horizon when the backend opts in. MK cannot
        // actually evict a server-resident model (e.g. Ollama holds it in VRAM);
        // it can only advise the server how long to keep it. Translating the
        // idle timeout here keeps the owned (in-process) and advisory
        // (server-side) timers in agreement instead of diverging. A `.never`
        // policy (`idleTimeout == nil`) gives no advice — the backend keeps its
        // own default.
        if let advisory = newBackend as? AdvisoryResidencyConfigurable {
            advisory.applyAdvisoryKeepAlive(idleTimeout: keepAlivePolicy.idleTimeout)
        }

        let cloudBackendName = backendDisplayName(for: endpoint.provider)
        let backendURL = url
        let cloudPlan = ModelLoadPlan.cloud()
        try await runLoad(
            source: "cloud",
            target: endpoint.provider.rawValue,
            backendName: cloudBackendName,
            backend: newBackend,
            modelName: endpoint.modelName,
            endpointID: endpoint.id
        ) {
            try await newBackend.loadModel(from: backendURL, plan: cloudPlan)
        }
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Does NOT stop generation — that is the facade's responsibility.
    /// The facade calls `stopGeneration()` before delegating here.
    func unloadModel() {
        cancelIdleWatchTask()
        invalidateOutstandingLoads()
        backend?.unloadModel()
        backend = nil
        isModelLoaded = false
        activeBackendName = nil
        activeModelName = nil
        activeEndpointID = nil
        loadedAt = nil
        residentFootprintBytes = nil
        // Drop the embedded template so a subsequent templateless load does not
        // inherit the previous model's Jinja (#1811).
        selectedChatTemplateRaw = nil
    }

    // MARK: - Capability Queries

    var capabilities: BackendCapabilities? {
        backend?.capabilities
    }

    var tokenizer: (any TokenizerProvider)? {
        (backend as? TokenizerVendor)?.tokenizer
    }

    func registeredBackendSnapshot() -> EnabledBackends {
        EnabledBackends(
            localModelTypes: supportedLocalModelTypes,
            cloudProviders: supportedCloudProviders
        )
    }

    func resetConversation() {
        backend?.resetConversation()
    }

    func secureWipe() {
        backend?.secureWipe()
    }

    // MARK: - Compatibility

    func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        if supportedLocalModelTypes.contains(modelType) {
            return .supported
        }
        return .unsupported(reason: unavailableReasonString(for: modelType))
    }

    func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        if supportedCloudProviders.contains(provider) {
            return .supported
        }
        return .unsupported(reason: "No backend registered for \(provider.rawValue). Register a cloud backend factory at startup.")
    }

    // MARK: - Backend Selection (Private)

    /// Returns a new plan with its verdict rewritten to `.warn` while preserving
    /// every other field. Used when the deny policy chooses to proceed despite
    /// `.deny`, so the backend's `plan.verdict != .deny` precondition holds.
    private func downgradeDenyToWarn(_ plan: ModelLoadPlan) -> ModelLoadPlan {
        ModelLoadPlan(
            inputs: plan.inputs,
            outcome: ModelLoadPlan.Outcome(
                effectiveContextSize: plan.outcome.effectiveContextSize,
                estimatedResidentBytes: plan.outcome.estimatedResidentBytes,
                estimatedKVBytes: plan.outcome.estimatedKVBytes,
                totalEstimatedBytes: plan.outcome.totalEstimatedBytes,
                verdict: .warn,
                reasons: plan.outcome.reasons
            )
        )
    }

    private func createBackend(for modelType: ModelType) -> (any InferenceBackend)? {
        for factory in backendFactories {
            if let backend = factory(modelType) {
                return backend
            }
        }
        return nil
    }

    private func createCloudBackend(for provider: APIProvider) -> (any InferenceBackend)? {
        for factory in cloudBackendFactories {
            if let backend = factory(provider) {
                return backend
            }
        }
        return nil
    }

    private func backendDisplayName(for modelType: ModelType) -> String {
        BackendDescriptorRegistry.shared.descriptor(for: modelType)?.engineLabel
            ?? String(describing: modelType)
    }

    /// Maps an `APIProvider` to a canonical backend-name string so cloud
    /// loads emit the same `BackendName.<case>.rawValue` shape as local
    /// loads where possible. Falls back to the raw provider ID for providers
    /// that don't have a registered descriptor (e.g. third-party providers
    /// registered at runtime before a descriptor is added).
    private func backendDisplayName(for provider: APIProvider) -> String {
        BackendDescriptorRegistry.shared.descriptor(for: provider)?.engineLabel
            ?? provider.rawValue
    }

    // MARK: - Load Token Lifecycle (Private)

    private func beginLoadRequest(
        source: String,
        target: String,
        backend: String
    ) -> LoadRequestToken {
        let request = LoadRequestToken(rawValue: nextLoadRequestToken.rawValue + 1)
        nextLoadRequestToken = request
        latestRequestedLoadToken = request
        loadPhase = .loading(request: request)
        modelLoadProgress = 0.0
        loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: source,
            target: target,
            backend: backend,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        logLoadEvent("load.start", request: request)
        return request
    }

    @discardableResult
    private func finishLoadAttemptWithFailure(_ request: LoadRequestToken, error: any Error) -> Bool {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else {
            logLoadEvent("load.suppress", request: request, reason: "stale-failure", clearMetadata: true)
            return true
        }
        loadPhase = .idle
        modelLoadProgress = nil
        logLoadEvent(
            "load.failed",
            request: request,
            reason: String(reflecting: type(of: error)),
            clearMetadata: true
        )
        return false
    }

    private func invalidateOutstandingLoads() {
        if case .loading(let activeRequest) = loadPhase {
            logLoadEvent("load.cancel", request: activeRequest, reason: "unload")
        }
        if let latestRequestedLoadToken {
            invalidatedThroughToken = max(invalidatedThroughToken, latestRequestedLoadToken)
        }
        loadPhase = .idle
        modelLoadProgress = nil
    }

    private func canCommitLoad(_ request: LoadRequestToken) -> Bool {
        guard request > invalidatedThroughToken else { return false }
        guard latestRequestedLoadToken == request else { return false }
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else { return false }
        return true
    }

    @discardableResult
    private func commitLoadIfCurrent(
        request: LoadRequestToken,
        backend newBackend: any InferenceBackend,
        backendName: String,
        modelName: String,
        endpointID: UUID? = nil,
        footprintBytes: UInt64? = nil
    ) -> Bool {
        guard canCommitLoad(request) else { return false }
        backend = newBackend
        isModelLoaded = true
        modelLoadProgress = nil
        activeBackendName = backendName
        activeModelName = modelName
        activeEndpointID = endpointID
        loadedAt = Date()
        residentFootprintBytes = footprintBytes
        loadPhase = .loaded(request: request)
        logLoadEvent("load.commit", request: request, clearMetadata: true)
        armIdleWatchTaskIfNeeded()
        return true
    }

    private func installProgressHandler(
        on newBackend: any InferenceBackend,
        for request: LoadRequestToken
    ) {
        guard let reporting = newBackend as? LoadProgressReporting else { return }
        reporting.setLoadProgressHandler { [weak self] progress in
            await MainActor.run { [weak self] in
                self?.applyLoadProgress(progress, for: request)
            }
        }
    }

    private func applyLoadProgress(_ progress: Double, for request: LoadRequestToken) {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else { return }
        modelLoadProgress = max(0.0, min(1.0, progress))
    }

    private func modelTypeLogLabel(_ modelType: ModelType) -> String {
        BackendDescriptorRegistry.shared.descriptor(for: modelType)?.engineLabel
            ?? String(describing: modelType)
    }

    private func logLoadEvent(
        _ event: String,
        request: LoadRequestToken,
        reason: String? = nil,
        clearMetadata: Bool = false
    ) {
        let metadata = loadRequestMetadataByToken[request]
        let latencyMs = metadata.map {
            max(0, Int((ProcessInfo.processInfo.systemUptime - $0.startedAtUptime) * 1_000))
        }

        var message = "event=\(event) req=\(request.rawValue)"
        if let metadata {
            message += " source=\(metadata.source) target=\(metadata.target) backend=\(metadata.backend)"
        }
        if let latencyMs {
            message += " latency_ms=\(latencyMs)"
        }
        if let reason {
            message += " reason=\(reason)"
        }

        if event == "load.failed" {
            Log.inference.error("\(message, privacy: .public)")
        } else {
            Log.inference.info("\(message, privacy: .public)")
        }

        if clearMetadata {
            loadRequestMetadataByToken.removeValue(forKey: request)
        }
    }

    private func unavailableReasonString(for modelType: ModelType) -> String {
        switch modelType {
        case .gguf:
            return "GGUF models require the llama.cpp backend. Build with the Llama Swift package dependency to enable it."
        case .mlx:
            return "MLX models require Apple Silicon and the MLX backend. Build with the MLX Swift package dependency to enable it."
        case .foundation:
            return "Apple Foundation Models require iOS 26 / macOS 26 or later."
        }
    }

    // MARK: - Keep-Alive Idle Watch (Private)

    /// Re-evaluates the keep-alive policy whenever it changes.
    ///
    /// Called via `keepAlivePolicy.didSet`. If a model is already loaded and
    /// the new policy has a non-nil timeout, re-arms the watch task. If the
    /// new policy is `.never`, the current watch task (if any) is cancelled.
    private func applyKeepAlivePolicy() {
        guard isModelLoaded else { return }
        if keepAlivePolicy.idleTimeout != nil {
            armIdleWatchTaskIfNeeded()
        } else {
            cancelIdleWatchTask()
        }
    }

    /// Arms the idle watch task when a policy with a non-nil timeout is active.
    ///
    /// Any previously running watch task is cancelled first so rearming after a
    /// new model load or policy change is always clean.
    private func armIdleWatchTaskIfNeeded() {
        guard let timeout = keepAlivePolicy.idleTimeout else { return }
        cancelIdleWatchTask()

        // Poll interval: check no more frequently than once every 10 seconds,
        // but also no less frequently than once per quarter of the timeout
        // window so short timeouts (e.g. 0.5 s in tests) still fire promptly.
        let pollInterval = min(max(timeout / 4, 0.1), 10.0)

        idleWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(pollInterval))
                } catch {
                    // Sleep was cancelled — exit cleanly.
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }

                // Check idle duration against the current policy (the policy
                // may have been updated since the task was armed).
                guard let currentTimeout = self.keepAlivePolicy.idleTimeout else { return }
                let idle = self.idleDurationProvider?() ?? TimeInterval.infinity
                if idle >= currentTimeout {
                    Log.inference.info("KeepAlivePolicy: idle \(idle, privacy: .public)s >= timeout \(currentTimeout, privacy: .public)s — requesting auto-unload")
                    self.unloadRequestHandler?(.idleTimeout)
                    return
                }
            }
        }
    }

    /// Cancels and nils the idle watch task.
    private func cancelIdleWatchTask() {
        idleWatchTask?.cancel()
        idleWatchTask = nil
    }
}
