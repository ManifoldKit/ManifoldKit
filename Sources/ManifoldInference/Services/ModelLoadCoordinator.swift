import Foundation

// MARK: - LoadIntent

/// The two kinds of load request that can be dispatched to the coordinator.
public enum LoadIntent: Sendable {
    case localModel(ModelInfo)
    case cloudEndpoint(APIEndpointRecord)
}

// MARK: - ModelLoadCoordinator

/// Owns the "latest-wins with cancellation" model-load state machine extracted
/// from `ChatViewModel` (phase 3 of #329).
///
/// Relocated from `ManifoldUI` to `ManifoldInference` so `InferenceService` can
/// **own and vend a single instance** ("one coordinator per service" is now
/// structural). Two consumers over one `InferenceService` — the existing
/// `ChatViewModel` and a future headless `ModelSelection` façade — must share the
/// same coordinator: two coordinators over one service would cross-talk on the
/// shared `InferenceService.modelLoadProgress` scalar.
///
/// The coordinator is `@MainActor` but NOT `@Observable` — it holds no
/// SwiftUI-observed state of its own. Chat-specific observable side-effects are
/// routed through the callback seams set at construction; the multi-observer
/// progress / phase / error path is published via ``statusUpdates()``.
///
/// ## Race safety
///
/// The wrapping-add generation counter (`latestLoadIntentGeneration &+= 1`) and
/// the "guard-before-proceed" pattern at every suspension point reproduce the
/// same defense-in-depth strategy that was in `ChatViewModel` before extraction:
///
/// - This layer cancels superseded async tasks before they reach `InferenceService`.
/// - `InferenceService` suppresses any stale completion that does reach it via its
///   own monotonic `LoadRequestToken`.
@MainActor
public final class ModelLoadCoordinator {

    // MARK: - Seams (set by ChatViewModel at init)

    /// Forwards to `ChatViewModel.transitionPhase(to:)`. Returns `true` if the
    /// transition was accepted (matches `transitionPhase`'s own return value).
    public var onTransitionPhase: @MainActor (BackendActivityPhase) -> Bool = { _ in false }

    /// Forwards to setting `ChatViewModel.errorMessage` to a non-nil string.
    public var onSurfaceError: @MainActor (String) -> Void = { _ in }

    /// Clears `ChatViewModel.errorMessage` (sets it to `nil`).
    public var onClearError: @MainActor () -> Void = {}

    /// Forwards to setting `ChatViewModel.selectedPromptTemplate`.
    public var onSetSelectedPromptTemplate: @MainActor (PromptTemplate) -> Void = { _ in }

    /// Forwards to `ChatViewModel.invalidateTokenCaches()`.
    public var onInvalidateTokenCaches: @MainActor () -> Void = {}

    /// Returns `ChatViewModel.isRestoringSession`.
    public var isRestoringSession: @MainActor () -> Bool = { false }

    /// Returns `ChatViewModel.activityPhase`.
    public var currentActivityPhase: @MainActor () -> BackendActivityPhase = { .idle }

    /// Returns the `ModelLoadPlan.Environment` to use for local-model load plans.
    public var currentLoadPlanEnvironment: @MainActor () -> ModelLoadPlan.Environment = { .current }

    // MARK: - Multi-observer load-status surface

    /// The most recent published load status. New subscribers receive this as their
    /// first element so a late observer is not stuck on a stale `.idle`.
    public private(set) var status: ModelLoadStatus = .idle

    /// Live fan-out continuations, keyed by subscription token. Each observer owns
    /// one entry; publishing fans out to all of them. Unbounded buffering with the
    /// newest value winning keeps observers from blocking the load path.
    private var statusContinuations: [UUID: AsyncStream<ModelLoadStatus>.Continuation] = [:]

    /// Returns a fresh `AsyncStream` of load-status transitions for one observer.
    ///
    /// Multiple observers (e.g. `ChatViewModel` AND a headless façade) may each call
    /// this and watch the *same* load without clobbering each other — this replaces
    /// the single-owner callback pattern for the progress / phase / error path. The
    /// stream yields the current ``status`` immediately, then every subsequent
    /// transition. It finishes when the coordinator is deinitialised.
    public func statusUpdates() -> AsyncStream<ModelLoadStatus> {
        let token = UUID()
        let current = status
        return AsyncStream { continuation in
            statusContinuations[token] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                // onTermination can fire off-actor; hop back to drop the entry.
                Task { @MainActor [weak self] in
                    self?.statusContinuations[token] = nil
                }
            }
        }
    }

    /// Publishes a new status to every subscribed observer and records it as the
    /// latest value. Idempotent: re-publishing the same status is a no-op so we
    /// don't wake observers on redundant transitions.
    private func publish(_ newStatus: ModelLoadStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in statusContinuations.values {
            continuation.yield(newStatus)
        }
    }

    // MARK: - State

    /// Polling interval for the model-load progress bridge task that mirrors
    /// `inferenceService.modelLoadProgress` into the view model's `activityPhase`.
    /// Tests may override this to a small value for deterministic timing.
    public var progressBridgePollInterval: Duration = .milliseconds(50)

    /// Minimum interval between published phase transitions for in-flight
    /// model-load progress. Keeps steadily-progressing backends from
    /// re-rendering every view observing `activityPhase` on every poll tick.
    /// The first emission in a load cycle and the terminal (≥ 1.0) emission
    /// always publish regardless of this window.
    public var progressBridgeMinTransitionInterval: Duration = .milliseconds(250)

    /// Timestamp of the most recent published phase transition from
    /// `applyModelLoadProgress`. `nil` means the next progress change will
    /// publish immediately (either because no progress has been published yet
    /// in this load cycle or a fresh cycle just began).
    var lastProgressTransitionInstant: ContinuousClock.Instant?

    /// The currently running coordinated load task, if any.
    var coordinatedLoadTask: Task<Void, Never>?

    /// Monotonic generation counter. Incremented (with wrapping) each time a
    /// new load intent supersedes the previous one, allowing stale async
    /// continuations to detect they are no longer current.
    var latestLoadIntentGeneration: UInt64 = 0

    /// Whether the **current** load generation should drive the chat-only
    /// callback seams (`onTransitionPhase`, `onSurfaceError`, `onClearError`,
    /// `onSetSelectedPromptTemplate`).
    ///
    /// The coordinator is shared per `InferenceService` (one instance for the
    /// `ChatViewModel` and any headless `ModelSelection`). A headless load must
    /// NOT push the chat surface into a `.modelLoading` phase or write its
    /// `errorMessage` — those seams belong to the chat VM's own loads. Headless
    /// observers watch the shared progress/phase/error path through
    /// ``statusUpdates()`` instead, which always fans out regardless of this flag.
    /// Latest-wins cancellation means only the current generation's UI state is
    /// ever applied, so a single flag tracking the current generation is correct.
    private var currentLoadDrivesChatSeams: Bool = true

    // MARK: - Dependencies (injected by InferenceService)

    private let inferenceService: InferenceService

    // MARK: - Init

    public init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    // MARK: - Public Interface (called from ChatViewModel facade)

    /// Dispatches a load for the given intent. The newest dispatch always wins;
    /// any older in-flight coordinated load is cancelled and invalidated.
    ///
    /// - Parameters:
    ///   - intent: The load to perform.
    ///   - drivesChatSeams: When `true` (the chat path) the load drives the
    ///     chat-only callback seams (phase / error / prompt template). When
    ///     `false` (a headless ``ModelSelection`` load) those seams are
    ///     suppressed so a foreign load never pushes the chat surface into a
    ///     loading phase; headless observers still see the load via
    ///     ``statusUpdates()``.
    public func dispatchLoad(_ intent: LoadIntent, drivesChatSeams: Bool = true) {
        let generation = nextLoadIntentGeneration(cancelInFlightTask: true)
        currentLoadDrivesChatSeams = drivesChatSeams
        coordinatedLoadTask = Task { [weak self] in
            await self?.performLoad(intent, generation: generation)
        }
    }

    /// Cancels any in-flight coordinated load and (optionally) resets the
    /// activity phase back to `.idle`. Called from `unloadModel()` and
    /// `handleMemoryPressure()` on the VM.
    public func invalidatePendingLoadIntent(resetActivityPhase: Bool = false) {
        _ = nextLoadIntentGeneration(cancelInFlightTask: true)
        if resetActivityPhase, case .modelLoading = currentActivityPhase() {
            _ = onTransitionPhase(.idle)
        }
        // A cancelled / invalidated load is no longer in flight: collapse the
        // headless status to idle so observers don't sit on a stale `.loading`.
        publish(.idle)
    }

    // MARK: - Load Entry Points (called from ChatViewModel for non-dispatch paths)

    public func loadLocalModel(_ model: ModelInfo, generation: UInt64?) async {
        guard isCurrentLoadIntentGeneration(generation) else { return }

        // Clamp the local-model context request. Some headers advertise a huge
        // native context (e.g. Gemma 4 26B-A4B reports 262_144) and although
        // ModelLoadPlan further clamps based on system RAM, Metal command-buffer
        // / one-shot KV-cache allocations on Apple Silicon still fail at high
        // ctx for large MoE GGUFs. 8192 is a safe ceiling for ~16 GB Q4 MoE on
        // unified memory; sessions can opt back into longer contexts via
        // contextSizeOverride once we surface a UI control.
        let detected = model.detectedContextLength ?? 8_192
        let requestedContext = min(detected, 8_192)
        let plan: ModelLoadPlan
        switch model.modelType {
        case .foundation:
            plan = ModelLoadPlan.systemManaged(requestedContextSize: requestedContext)
        case .gguf:
            plan = ModelLoadPlan.compute(
                for: model,
                requestedContextSize: requestedContext,
                strategy: .mappable,
                environment: currentLoadPlanEnvironment()
            )
        case .mlx:
            plan = ModelLoadPlan.compute(
                for: model,
                requestedContextSize: requestedContext,
                strategy: .resident,
                environment: currentLoadPlanEnvironment()
            )
        }

        switch plan.verdict {
        case .deny:
            setLoadErrorIfCurrent(
                loadPlanDenyMessage(for: plan, model: model),
                generation: generation
            )
            return
        case .warn:
            Log.inference.warning(
                "Proceeding with tight-fit model load: \(model.name) — \(String(describing: plan.reasons))"
            )
        case .allow:
            break
        }

        // Auto-detect prompt template from GGUF metadata before loading.
        if let detected = model.detectedPromptTemplate,
           isCurrentLoadIntentGeneration(generation),
           currentLoadDrivesChatSeams {
            onSetSelectedPromptTemplate(detected)
            Log.inference.info("Auto-detected prompt template: \(detected.rawValue)")
        }

        guard beginLoadUIState(generation: generation) else { return }
        let bridge = Task { @MainActor [weak self] in
            await self?.observeModelLoadProgress(generation: generation)
        }
        defer {
            bridge.cancel()
            endLoadUIState(generation: generation)
        }

        do {
            try await inferenceService.loadModel(from: model, plan: plan)
            publishLoadedIfCurrent(generation: generation)
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to load model: \(error.localizedDescription)", generation: generation)
        }
    }

    public func loadCloudEndpointInternal(_ endpoint: APIEndpointRecord, generation: UInt64?) async {
        guard beginLoadUIState(generation: generation) else { return }
        let bridge = Task { @MainActor [weak self] in
            await self?.observeModelLoadProgress(generation: generation)
        }
        defer {
            bridge.cancel()
            endLoadUIState(generation: generation)
        }

        do {
            try await inferenceService.loadEndpointBackend(from: endpoint)
            publishLoadedIfCurrent(generation: generation)
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to connect: \(error.localizedDescription)", generation: generation)
        }
    }

    // MARK: - Generation Counter

    @discardableResult
    func nextLoadIntentGeneration(cancelInFlightTask: Bool) -> UInt64 {
        latestLoadIntentGeneration &+= 1
        if cancelInFlightTask {
            coordinatedLoadTask?.cancel()
            coordinatedLoadTask = nil
        }
        return latestLoadIntentGeneration
    }

    // MARK: - Private Helpers

    private func performLoad(_ intent: LoadIntent, generation: UInt64?) async {
        switch intent {
        case .localModel(let model):
            await loadLocalModel(model, generation: generation)
        case .cloudEndpoint(let endpoint):
            await loadCloudEndpointInternal(endpoint, generation: generation)
        }
    }

    func isCurrentLoadIntentGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return generation == latestLoadIntentGeneration
    }

    private func beginLoadUIState(generation: UInt64?) -> Bool {
        guard isCurrentLoadIntentGeneration(generation) else { return false }
        let progress = inferenceService.modelLoadProgress
        if currentLoadDrivesChatSeams {
            onClearError()
            lastProgressTransitionInstant = nil
            _ = onTransitionPhase(.modelLoading(progress: progress))
        }
        publish(.loading(progress: progress))
        return true
    }

    /// Mirrors `inferenceService.modelLoadProgress` into `activityPhase` for
    /// the duration of a model load. Polls instead of using
    /// `withObservationTracking` so cancellation is reliable — observation
    /// continuations don't resume on `Task.cancel()`, which makes them
    /// deadlock-prone for a long-running mirror like this.
    ///
    /// The bridge only writes when the load generation is still current AND
    /// `activityPhase` is still `.modelLoading`, so any late wake-up after
    /// `endLoadUIState` has flipped the phase to `.idle` is a no-op.
    private func observeModelLoadProgress(generation: UInt64?) async {
        while !Task.isCancelled {
            applyModelLoadProgress(generation: generation)
            do {
                try await Task.sleep(for: progressBridgePollInterval)
            } catch {
                // Sleep throws on cancel; one final apply ensures the latest
                // value is published before the bridge exits.
                applyModelLoadProgress(generation: generation)
                return
            }
        }
    }

    private func applyModelLoadProgress(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        let snapshot = inferenceService.modelLoadProgress

        // Headless mirror: fan out in-flight progress to `statusUpdates()`
        // observers independent of the chat phase. A headless load never sets the
        // chat `activityPhase`, so this must not be gated on it. `publish` is
        // idempotent, so a repeated value is dropped.
        if case .loading = status {
            publish(.loading(progress: snapshot))
        }

        // Chat-seam mirror: only when this load drives the chat surface AND the
        // chat phase is still `.modelLoading` (so a late wake-up after the phase
        // flipped to `.idle` is a no-op).
        guard currentLoadDrivesChatSeams else { return }
        guard case .modelLoading(let current) = currentActivityPhase() else { return }
        guard current != snapshot else { return }

        // Terminal progress (>= 1.0) and the first emission after a new load
        // cycle bypass the throttle so the progress UI feels immediate at the
        // start and lands cleanly at 100% before the phase flips to .idle.
        let isTerminal = (snapshot ?? 0.0) >= 1.0
        let now = ContinuousClock.now
        if let last = lastProgressTransitionInstant,
           !isTerminal,
           now - last < progressBridgeMinTransitionInterval {
            return
        }

        if onTransitionPhase(.modelLoading(progress: snapshot)) {
            lastProgressTransitionInstant = now
        }
    }

    private func endLoadUIState(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        lastProgressTransitionInstant = nil
        if currentLoadDrivesChatSeams, case .modelLoading = currentActivityPhase() {
            _ = onTransitionPhase(.idle)
        }
        // A load cycle that ended without committing or failing (e.g. a `.deny`
        // returned before the load began, or a superseded generation) collapses
        // the headless status back to idle. A successful `.loaded` or a `.failed`
        // was already published on the relevant path and is preserved here because
        // `endLoadUIState` only resets a still-`loading` status.
        if case .loading = status {
            publish(.idle)
        }
    }

    private func setLoadErrorIfCurrent(_ message: String, generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        if currentLoadDrivesChatSeams {
            onSurfaceError(message)
        }
        publish(.failed(reason: message))
    }

    private func publishLoadedIfCurrent(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        publish(.loaded)
    }

    /// Translates a denied plan's primary `Reason` into a user-visible message.
    ///
    /// Picks the first `.insufficientResident` or `.insufficientKVCache` as the
    /// primary reason; clamp reasons (info-only) are not surfaced. Falls back to
    /// the legacy shape when no primary reason is present.
    private func loadPlanDenyMessage(for plan: ModelLoadPlan, model: ModelInfo) -> String {
        let primary = plan.reasons.first { reason in
            switch reason {
            case .insufficientResident, .insufficientKVCache: return true
            default: return false
            }
        }
        switch primary {
        case .insufficientResident(let required, let available):
            return "This model (\(Self.formatBytes(required))) is too large for available memory (\(Self.formatBytes(available))). Try a smaller quantisation."
        case .insufficientKVCache(let required, let available):
            return "Model weights fit, but the requested context window doesn't (\(Self.formatBytes(required)) needed vs \(Self.formatBytes(available)) available). Try reducing the context size or closing other apps."
        default:
            return "This model (\(model.fileSizeFormatted)) may be too large for this device. Try a smaller quantisation."
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
