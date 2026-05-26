import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - LoadIntent

/// The two kinds of load request that can be dispatched to the coordinator.
enum LoadIntent {
    case localModel(ModelInfo)
    case cloudEndpoint(APIEndpointRecord)
}

// MARK: - ModelLoadCoordinator

/// Owns the "latest-wins with cancellation" model-load state machine extracted
/// from `ChatViewModel` (phase 3 of #329).
///
/// The coordinator is `@MainActor` but NOT `@Observable` — it holds no
/// SwiftUI-observed state of its own. All observable side-effects are routed
/// back to `ChatViewModel` through the callback seams set at construction.
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
final class ModelLoadCoordinator {

    // MARK: - Seams (set by ChatViewModel at init)

    /// Forwards to `ChatViewModel.transitionPhase(to:)`. Returns `true` if the
    /// transition was accepted (matches `transitionPhase`'s own return value).
    var onTransitionPhase: @MainActor (BackendActivityPhase) -> Bool = { _ in false }

    /// Forwards to setting `ChatViewModel.errorMessage` to a non-nil string.
    var onSurfaceError: @MainActor (String) -> Void = { _ in }

    /// Clears `ChatViewModel.errorMessage` (sets it to `nil`).
    var onClearError: @MainActor () -> Void = {}

    /// Forwards to setting `ChatViewModel.selectedPromptTemplate`.
    var onSetSelectedPromptTemplate: @MainActor (PromptTemplate) -> Void = { _ in }

    /// Forwards to `ChatViewModel.invalidateTokenCaches()`.
    var onInvalidateTokenCaches: @MainActor () -> Void = {}

    /// Returns `ChatViewModel.isRestoringSession`.
    var isRestoringSession: @MainActor () -> Bool = { false }

    /// Returns `ChatViewModel.activityPhase`.
    var currentActivityPhase: @MainActor () -> BackendActivityPhase = { .idle }

    /// Returns the `ModelLoadPlan.Environment` to use for local-model load plans.
    var currentLoadPlanEnvironment: @MainActor () -> ModelLoadPlan.Environment = { .current }

    // MARK: - State

    /// Polling interval for the model-load progress bridge task that mirrors
    /// `inferenceService.modelLoadProgress` into the view model's `activityPhase`.
    /// Tests may override this to a small value for deterministic timing.
    var progressBridgePollInterval: Duration = .milliseconds(50)

    /// Minimum interval between published phase transitions for in-flight
    /// model-load progress. Keeps steadily-progressing backends from
    /// re-rendering every view observing `activityPhase` on every poll tick.
    /// The first emission in a load cycle and the terminal (≥ 1.0) emission
    /// always publish regardless of this window.
    var progressBridgeMinTransitionInterval: Duration = .milliseconds(250)

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

    // MARK: - Dependencies (injected by ChatViewModel)

    private let inferenceService: InferenceService

    // MARK: - Init

    init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    // MARK: - Public Interface (called from ChatViewModel facade)

    /// Dispatches a load for the given intent. The newest dispatch always wins;
    /// any older in-flight coordinated load is cancelled and invalidated.
    func dispatchLoad(_ intent: LoadIntent) {
        let generation = nextLoadIntentGeneration(cancelInFlightTask: true)
        coordinatedLoadTask = Task { [weak self] in
            await self?.performLoad(intent, generation: generation)
        }
    }

    /// Cancels any in-flight coordinated load and (optionally) resets the
    /// activity phase back to `.idle`. Called from `unloadModel()` and
    /// `handleMemoryPressure()` on the VM.
    func invalidatePendingLoadIntent(resetActivityPhase: Bool = false) {
        _ = nextLoadIntentGeneration(cancelInFlightTask: true)
        if resetActivityPhase, case .modelLoading = currentActivityPhase() {
            _ = onTransitionPhase(.idle)
        }
    }

    // MARK: - Load Entry Points (called from ChatViewModel for non-dispatch paths)

    func loadLocalModel(_ model: ModelInfo, generation: UInt64?) async {
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
           isCurrentLoadIntentGeneration(generation) {
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
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to load model: \(error.localizedDescription)", generation: generation)
        }
    }

    func loadCloudEndpointInternal(_ endpoint: APIEndpointRecord, generation: UInt64?) async {
        guard beginLoadUIState(generation: generation) else { return }
        let bridge = Task { @MainActor [weak self] in
            await self?.observeModelLoadProgress(generation: generation)
        }
        defer {
            bridge.cancel()
            endLoadUIState(generation: generation)
        }

        do {
            try await inferenceService.loadCloudBackend(from: endpoint)
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
        onClearError()
        lastProgressTransitionInstant = nil
        _ = onTransitionPhase(.modelLoading(progress: inferenceService.modelLoadProgress))
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
        guard case .modelLoading(let current) = currentActivityPhase() else { return }
        let snapshot = inferenceService.modelLoadProgress
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
        if case .modelLoading = currentActivityPhase() {
            _ = onTransitionPhase(.idle)
        }
    }

    private func setLoadErrorIfCurrent(_ message: String, generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        onSurfaceError(message)
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
