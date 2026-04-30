import Foundation
import Observation

/// Owns backend registration, model loading/unloading, the `LoadRequestToken`
/// lifecycle, progress reporting, deny-policy enforcement, and capability/compatibility queries.
///
/// This is an internal implementation detail of `BaseChatInference`.
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

    // MARK: - Backend

    private(set) var backend: (any InferenceBackend)?

    // MARK: - Deny Policy

    /// Policy applied when a ``ModelLoadPlan`` returns a `.deny` verdict.
    /// Mirrors the facade's `InferenceService.denyPolicy`; written by the facade's
    /// `didSet` so tests and custom gates can swap it before each load.
    var denyPolicy: LoadDenyPolicy = .platformDefault

    // MARK: - Prompt Template

    var selectedPromptTemplate: PromptTemplate = .chatML

    // MARK: - Backend Registry

    private var backendFactories: [BackendFactory] = []
    private var cloudBackendFactories: [CloudBackendFactory] = []
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

    #if DEBUG
    /// Test-only seam for preloading a backend without driving the real load
    /// pipeline.
    ///
    /// - Parameters:
    ///   - backend: the pre-configured backend to install as current.
    ///   - name: the backend engine label (e.g. "llama.cpp", "MLX"). Stored in
    ///     ``activeBackendName`` and in request metadata as the `backend` field.
    ///   - modelName: the human-readable model name (e.g. from `ModelInfo.name`).
    ///     Stored in ``activeModelName``. Defaults to `nil` when the test did not
    ///     load through the real pipeline and therefore has no model-level name.
    init(backend: any InferenceBackend, name: String = "Mock", modelName: String? = nil) {
        self.backend = backend
        self.isModelLoaded = true
        self.activeBackendName = name
        self.activeModelName = modelName
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
    #endif

    // MARK: - Backend Registration

    func registerBackendFactory(_ factory: @escaping BackendFactory) {
        backendFactories.append(factory)
    }

    func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
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
                + "Register a BackendFactory before loading models."
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
                + "Register a BackendFactory before loading models."
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
        let request = beginLoadRequest(
            source: "local",
            target: modelTypeLogLabel(modelInfo.modelType),
            backend: backendName
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            let url = modelInfo.url
            let mmprojURL = modelInfo.mmprojURL
            let dispatchPlan = effectivePlan
            try await Task.detached(priority: .userInitiated) {
                (newBackend as? MultimodalProjectorConfigurable)?.setMmprojURL(mmprojURL)
                try await newBackend.loadModel(from: url, plan: dispatchPlan)
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
        guard commitLoadIfCurrent(request: request, backend: newBackend, backendName: backendName, modelName: modelInfo.name) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    func loadCloudBackend(from endpoint: APIEndpointRecord) async throws {
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
                + "Register a CloudBackendFactory before loading cloud backends."
            )
        }

        switch endpoint.provider {
        case .claude, .openAI, .openAIResponses, .custom:
            guard let keychainConfigurable = newBackend as? CloudBackendKeychainConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendKeychainConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            keychainConfigurable.configure(
                baseURL: url,
                keychainAccount: endpoint.keychainAccount,
                modelName: endpoint.modelName
            )

        case .ollama, .lmStudio:
            guard let urlModelConfigurable = newBackend as? CloudBackendURLModelConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendURLModelConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            urlModelConfigurable.configure(baseURL: url, modelName: endpoint.modelName)
        }

        let request = beginLoadRequest(
            source: "cloud",
            target: endpoint.provider.rawValue,
            backend: endpoint.provider.rawValue
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            let backendURL = url
            let cloudPlan = ModelLoadPlan.cloud()
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: backendURL, plan: cloudPlan)
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
            backendName: endpoint.provider.rawValue,
            modelName: endpoint.modelName
        ) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Does NOT stop generation — that is the facade's responsibility.
    /// The facade calls `stopGeneration()` before delegating here.
    func unloadModel() {
        invalidateOutstandingLoads()
        backend?.unloadModel()
        backend = nil
        isModelLoaded = false
        activeBackendName = nil
        activeModelName = nil
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
        switch modelType {
        case .mlx: "MLX"
        case .gguf: "llama.cpp"
        case .foundation: "Apple"
        }
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
        modelName: String
    ) -> Bool {
        guard canCommitLoad(request) else { return false }
        backend = newBackend
        isModelLoaded = true
        modelLoadProgress = nil
        activeBackendName = backendName
        activeModelName = modelName
        loadPhase = .loaded(request: request)
        logLoadEvent("load.commit", request: request, clearMetadata: true)
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
        switch modelType {
        case .mlx: "mlx"
        case .gguf: "gguf"
        case .foundation: "foundation"
        }
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
}
