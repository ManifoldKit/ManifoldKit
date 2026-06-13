import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference
import ManifoldHuggingFace

public enum ModelImportError: LocalizedError, Equatable {
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported model format. Import a .gguf file or an MLX model folder containing config.json."
        }
    }
}

/// View model for the model browser and storage management sheets.
///
/// Coordinates HuggingFace search, curated recommendations, downloads, and
/// local model deletion. Injected into the view hierarchy via `@Environment`.
@Observable
@MainActor
public final class ModelManagementViewModel {

    // MARK: - Search State

    /// The current search query bound to the search field.
    public var searchQuery: String = ""

    /// Models returned from HuggingFace search.
    public private(set) var searchResults: [DownloadableModel] = []

    /// Curated models filtered to this device's recommended tier.
    public private(set) var recommendedModels: [DownloadableModel] = []

    /// Whether a search request is in flight.
    public private(set) var isSearching: Bool = false

    /// `true` when the last successful search used a direct repo lookup (via `getModelFiles`)
    /// rather than a freetext search. The UI uses this to label results contextually.
    public private(set) var isDirectRepoLookup: Bool = false

    /// User-facing error from the last search or download attempt.
    public var searchError: String?

    // MARK: - Recommendation State

    /// The use case the browser ranks search results for.
    ///
    /// Drives `rankedVariants(useCase:)` ordering. In-memory `@Observable` state with
    /// a `.general` default; persisted only when a `UserDefaults` is injected (see
    /// `init`). Changing it re-orders the list but never hides a model — ranking, not
    /// filtering, is the contract (see `SortMode`).
    public var selectedUseCase: ModelUseCase = .general {
        didSet { persistSelectedUseCase() }
    }

    /// How the browser orders search-result groups.
    ///
    /// The escape hatch for power users: `.recommended` applies device-aware fit
    /// ranking, `.size`/`.downloads` fall back to the pre-existing deterministic order
    /// so no model is ever buried behind a recommendation they disagree with.
    public enum SortMode: String, CaseIterable, Sendable {
        /// Device-aware fit ranking for `selectedUseCase` (the new default).
        case recommended
        /// Smallest on-disk size first — the historical compatibility-tier order.
        case size
        /// Most-downloaded first.
        case downloads

        /// Short label for a segmented control or menu.
        public var label: String {
            switch self {
            case .recommended: return "Recommended"
            case .size:        return "Size"
            case .downloads:   return "Downloads"
            }
        }
    }

    /// The active sort mode for the browser. In-memory; defaults to `.recommended`.
    public var sortMode: SortMode = .recommended

    // MARK: - Services

    private let huggingFaceService: (any HuggingFaceServiceProtocol)?
    private let downloadManager: (any BackgroundDownloadManaging)?
    private let deviceCapability: DeviceCapabilityService
    private let modelStorage: ModelStorageService
    private let diagnostics: DiagnosticsService?
    private let fileRemover: @Sendable (URL) throws -> Void

    /// Injected defaults store for persisting `selectedUseCase`.
    ///
    /// Never `UserDefaults.standard` implicitly — a shared instance is a documented
    /// `--parallel` flake source (#734, #761). Callers opt into persistence by passing
    /// a suite; the default `nil` keeps the picker purely in-memory.
    private let userDefaults: UserDefaults?

    /// Defaults key for the persisted use case. Namespaced to avoid host-app collisions.
    private static let selectedUseCaseKey = "ManifoldKit.ModelManagement.selectedUseCase"

    // MARK: - Download Tracking

    /// Mirrors `downloadManager.activeDownloads` as a stored property so that
    /// SwiftUI observation tracking works correctly. Computed properties that
    /// read from a nested `@Observable` object do not propagate change
    /// notifications to views observing this view model.
    public private(set) var trackedDownloads: [String: DownloadState] = [:]

    /// Polling task that syncs download state from the manager to this view model.
    private var downloadSyncTask: Task<Void, Never>?

    // MARK: - Benchmark

    /// Optional benchmark runner. Set this at app startup to enable the `runBenchmark` action.
    public var benchmarkRunner: (any ModelBenchmarkRunner)?

    /// `true` while a benchmark is in progress.
    public private(set) var isBenchmarking: Bool = false

    /// Benchmark results keyed by model file name, populated after each successful
    /// ``runBenchmark(for:)`` call and pre-loaded from ``ModelBenchmarkCache`` on context injection.
    public private(set) var benchmarkResults: [String: ModelBenchmarkResult] = [:]

    /// Storage-neutral cache for benchmark results. Set by host code at app
    /// startup (typically `ManifoldBootstrap.benchmarkCache`).
    ///
    /// Assigning this property immediately loads any previously cached results
    /// so UI can show historical data without re-running benchmarks. Replaces
    /// the previous public `modelContext: ModelContext?` SwiftData leak.
    public var benchmarkCache: (any BenchmarkCache)? {
        didSet { loadCachedBenchmarkResults() }
    }

    // MARK: - Active Model

    /// The file name of the currently active (loaded) model.
    ///
    /// Set externally by the host view whenever `ChatViewModel.selectedModel` changes,
    /// so `DownloadableModelRow` can distinguish the in-use model from other downloaded models.
    public var activeModelFileName: String?

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?

    /// Cached set of file names from `discoverModels()` to avoid N+1 filesystem scans.
    private var discoveredModelFileNames: Set<String>?

    /// Cached snapshot of models discovered on disk.
    ///
    /// Stored `@Observable` state — NOT a computed property — so SwiftUI reads it
    /// from a cache instead of triggering a ~2s synchronous disk scan on every
    /// `body` evaluation (#1787). Populated by ``refreshDiscoveredModels()``,
    /// which hops the scan off the main actor.
    public private(set) var discoveredModels: [ModelInfo] = []

    /// `true` while an off-main model discovery scan is in flight.
    public private(set) var isRefreshingModels = false

    /// `true` once the first discovery scan has completed (regardless of result).
    ///
    /// Lets the UI distinguish "scan in progress, no data yet" from "scanned,
    /// genuinely zero models" so it never paints a false "0 GB" on first render.
    public private(set) var hasLoadedModelsOnce = false

    /// The in-flight discovery task, used for single-flight de-duplication.
    private var refreshTask: Task<Void, Never>?

    // MARK: - Initialisation

    public init(
        huggingFaceService: (any HuggingFaceServiceProtocol)? = nil,
        downloadManager: (any BackgroundDownloadManaging)? = nil,
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        diagnostics: DiagnosticsService? = nil,
        userDefaults: UserDefaults? = nil,
        fileRemover: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.huggingFaceService = huggingFaceService
        self.downloadManager = downloadManager
        self.deviceCapability = deviceCapability
        self.modelStorage = modelStorage
        self.diagnostics = diagnostics
        self.userDefaults = userDefaults
        self.fileRemover = fileRemover
        restoreSelectedUseCase()
    }

    /// Creates a production-ready model manager with search and downloads enabled.
    public static func live(
        huggingFaceService: (any HuggingFaceServiceProtocol)? = nil,
        downloadManager: (any BackgroundDownloadManaging)? = nil,
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        diagnostics: DiagnosticsService? = nil
    ) -> ModelManagementViewModel {
        let resolvedService = huggingFaceService ?? HuggingFaceService()
        let resolvedDownloadManager = downloadManager ?? BackgroundDownloadManager()
        resolvedDownloadManager.reconnectBackgroundSession()
        return ModelManagementViewModel(
            huggingFaceService: resolvedService,
            downloadManager: resolvedDownloadManager,
            deviceCapability: deviceCapability,
            modelStorage: modelStorage,
            diagnostics: diagnostics
        )
    }

    /// Creates a lightweight model manager for Xcode previews.
    ///
    /// Skips URLSession background session reconnection and HuggingFace setup,
    /// which are unnecessary and slow in the preview environment.
    public static func preview() -> ModelManagementViewModel {
        ModelManagementViewModel(
            huggingFaceService: nil,
            downloadManager: nil,
            deviceCapability: DeviceCapabilityService(),
            modelStorage: ModelStorageService()
        )
    }

    // MARK: - Computed Properties

    /// The recommended model size tier for this device.
    public var recommendation: ModelSizeRecommendation {
        deviceCapability.recommendedModelSize()
    }

    /// Human-readable total storage used by downloaded models.
    ///
    /// Derived PURELY from the cached ``discoveredModels`` snapshot — it never
    /// touches disk, so reading it from a SwiftUI `body` is free (#1787). The
    /// cache is refreshed off-main by ``refreshDiscoveredModels()``.
    public var totalStorageUsed: String {
        let total = discoveredModels.reduce(UInt64(0)) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    /// All currently active downloads, keyed by model ID.
    public var activeDownloads: [String: DownloadState] {
        trackedDownloads
    }

    /// Whether any downloads are in progress.
    public var hasActiveDownloads: Bool {
        trackedDownloads.values.contains { state in
            switch state.status {
            case .queued, .downloading:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    /// Number of downloads that have reached the `.completed` state.
    ///
    /// The app can observe this via `onChange` to trigger a model-list refresh
    /// whenever a new download finishes, so the sidebar picker updates without
    /// requiring an app restart.
    public var completedDownloadCount: Int {
        trackedDownloads.values.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
    }

    /// Path to the models directory on disk.
    public var modelsDirectoryPath: String {
        modelStorage.modelsDirectory.path
    }

    // MARK: - Model Discovery (cached, off-main)

    /// Refreshes ``discoveredModels`` from disk, off the main actor, single-flight.
    ///
    /// Reads from disk exactly once per call; concurrent calls collapse into the
    /// in-flight task (`refreshTask != nil` short-circuit). The scan hops off the
    /// main actor inside ``ModelStorageService/discoverModelsOffMain()`` (the
    /// sanctioned `Task.detached` site) — this method itself uses a plain `Task`
    /// so it inherits `@MainActor` (CLAUDE.md Swift-6 gotcha #5).
    public func refreshDiscoveredModels() {
        if refreshTask != nil { return }
        isRefreshingModels = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performDiscoveryScan()
        }
    }

    /// Forces a fresh discovery scan, cancelling any in-flight scan and ignoring
    /// the single-flight guard. Use after a disk mutation (download/delete/import)
    /// or an explicit user pull-to-refresh, where the cached snapshot is known stale.
    public func forceRefreshDiscoveredModels() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshingModels = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performDiscoveryScan()
        }
    }

    /// Shared scan body for the refresh entry points. Runs the off-main scan,
    /// then assigns the cached state on the main actor.
    private func performDiscoveryScan() async {
        defer {
            isRefreshingModels = false
            refreshTask = nil
        }
        let result = await modelStorage.discoverModelsOffMain()
        guard !Task.isCancelled else { return }
        discoveredModels = result.models
        discoveredModelFileNames = Set(result.models.map(\.fileName))
        hasLoadedModelsOnce = true
    }

    // MARK: - Recommendations

    /// Loads curated model recommendations for this device's capability tier,
    /// or a caller-supplied curated preset when specific model IDs are preferred.
    public func loadRecommendations(preferredModelIDs: Set<String>? = nil) {
        let curatedModels: [CuratedModel]

        if let preferredModelIDs, !preferredModelIDs.isEmpty {
            curatedModels = CuratedModel.all.filter { preferredModelIDs.contains($0.id) }
        } else {
            curatedModels = CuratedModel.all.filter { $0.recommendedFor.contains(recommendation) }
        }

        recommendedModels = curatedModels.map { DownloadableModel(from: $0) }
    }

    // MARK: - Search

    /// Searches HuggingFace for models matching `searchQuery`.
    ///
    /// Debounces by 500ms so rapid typing doesn't fire excessive requests.
    /// `isSearching` is set to `true` immediately — before the debounce sleep —
    /// so the UI spinner appears as soon as the user types, not after the delay.
    ///
    /// When the query looks like a repo ID (`org/repo`), skips freetext search and
    /// calls `getModelFiles(repoID:)` directly. Falls back to freetext search if the
    /// direct lookup fails (repo not found, private, or network error).
    public func search() async {
        // Cancel any in-flight search.
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            isDirectRepoLookup = false
            return
        }

        guard let service = huggingFaceService else {
            searchError = "Model search is not available yet. Download services are being configured."
            return
        }

        searchError = nil
        // Set immediately so the UI shows a spinner during the debounce window,
        // not just after the 500ms delay has elapsed.
        isSearching = true

        let task = Task {
            // Debounce: wait 500ms before actually searching.
            try? await Task.sleep(for: .milliseconds(500))
            // When this task is cancelled a newer search() call is already running
            // and owns isSearching. Do NOT touch isSearching here — clearing it would
            // clobber the replacement task's spinner, which was set to true after the
            // cancel() call and before this guard runs on @MainActor.
            guard !Task.isCancelled else { return }

            if looksLikeRepoID(query) {
                // Attempt a direct repo lookup first; fall back to freetext on any error.
                do {
                    let results = try await service.getModelFiles(repoID: query)
                    guard !Task.isCancelled else { return }
                    searchResults = results
                    isDirectRepoLookup = true
                    Log.network.info("Direct repo lookup returned \(results.count) files for '\(query, privacy: .private)'")
                    isSearching = false
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    Log.network.warning("Direct repo lookup failed for '\(query, privacy: .private)', falling back to freetext: \(error)")
                }
            }

            do {
                let results = try await service.searchModels(query: query)
                guard !Task.isCancelled else { return }
                searchResults = results
                isDirectRepoLookup = false
                Log.network.info("Search returned \(results.count) results for '\(query, privacy: .private)'")
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Search failed: \(error.localizedDescription)"
                isDirectRepoLookup = false
                Log.network.error("Search error: \(error)")
            }

            isSearching = false
        }

        searchTask = task
        await task.value
    }

    /// Returns `true` when `query` matches the `owner/repo` pattern used by HuggingFace repo IDs.
    ///
    /// Requires exactly one `/` with non-empty, space-free text on both sides.
    /// URLs (which contain `://` or multiple slashes) and multi-segment paths do not match.
    private func looksLikeRepoID(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Require exactly one slash so that URLs and three-segment paths are rejected.
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    // MARK: - Downloads

    /// Starts downloading a model from HuggingFace.
    public func startDownload(_ model: DownloadableModel) {
        guard let service = huggingFaceService else {
            searchError = "Download services are not available yet."
            return
        }

        guard let manager = downloadManager else {
            searchError = "Download manager is not available yet."
            return
        }

        Task {
            do {
                let plan = try await service.downloadPlan(for: model)
                let state = try await manager.startDownload(model, plan: plan)
                trackedDownloads[model.id] = state
                Log.download.info("Started download: \(model.displayName), id=\(state.id)")
                startDownloadSync()
            } catch HuggingFaceError.insufficientDiskSpace(let required, let available) {
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                let requiredStr = fmt.string(fromByteCount: Int64(required))
                let availableStr = fmt.string(fromByteCount: Int64(available))
                searchError = "Not enough storage — this model needs \(requiredStr) but only \(availableStr) is available."
                Log.download.error("Insufficient disk space: need \(required) bytes, have \(available)")
            } catch {
                searchError = "Failed to start download: \(error.localizedDescription)"
                Log.download.error("Download start error: \(error)")
            }
        }
    }

    /// Polls the download manager for state changes and syncs to `trackedDownloads`.
    ///
    /// This bridges the gap between the `BackgroundDownloadManager` (which updates
    /// via URLSession delegate callbacks) and this view model's stored properties
    /// (which SwiftUI observes for re-rendering).
    ///
    /// Terminal states (`.failed`, `.cancelled`) are held briefly for user feedback,
    /// then swept from `trackedDownloads` so stale rows don't accumulate indefinitely.
    private func startDownloadSync() {
        guard downloadSyncTask == nil else { return }

        downloadSyncTask = Task { @MainActor [weak self] in
            // Timestamps of when each download first reached a terminal state.
            // Used to enforce a short display window before removal.
            var terminalSince: [String: Date] = [:]
            // IDs already counted as completed, so the discovery cache is
            // invalidated exactly once per finished download (#1774).
            var invalidatedForCompletion: Set<String> = []

            while !Task.isCancelled {
                guard let self, let manager = self.downloadManager else { break }

                // Sync all state from the manager.
                let managerDownloads = manager.activeDownloads
                for (id, state) in managerDownloads {
                    self.trackedDownloads[id] = state
                    // why: a finished download adds a new file on disk. Invalidate
                    // the discovery cache here (the single completion observation
                    // point) so every download path stays fresh without the old
                    // blanket onAppear rescan.
                    if case .completed = state.status, !invalidatedForCompletion.contains(id) {
                        invalidatedForCompletion.insert(id)
                        self.invalidateModelCache()
                    }
                }

                // Record when each download first reaches a terminal state.
                let now = Date()
                for (id, state) in self.trackedDownloads {
                    switch state.status {
                    case .failed, .cancelled:
                        if terminalSince[id] == nil {
                            terminalSince[id] = now
                        }
                    default:
                        terminalSince.removeValue(forKey: id)
                    }
                }

                // Remove terminal entries once their display window has elapsed.
                // .cancelled rows are cleared after ~1 s; .failed rows after ~3 s.
                for (id, since) in terminalSince {
                    guard let state = self.trackedDownloads[id] else {
                        terminalSince.removeValue(forKey: id)
                        continue
                    }
                    let elapsed = now.timeIntervalSince(since)
                    let window: TimeInterval
                    switch state.status {
                    case .cancelled: window = 1
                    case .failed: window = 3
                    default: continue
                    }
                    if elapsed >= window {
                        self.trackedDownloads.removeValue(forKey: id)
                        terminalSince.removeValue(forKey: id)
                    }
                }

                // Stop polling if no active downloads remain.
                let hasActive = managerDownloads.values.contains { state in
                    switch state.status {
                    case .queued, .downloading: return true
                    default: return false
                    }
                }

                if !hasActive && !managerDownloads.isEmpty && terminalSince.isEmpty {
                    // Final sync complete and all terminal windows have elapsed.
                    break
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.downloadSyncTask = nil
        }
    }

    /// Cancels an active download.
    public func cancelDownload(id: String) {
        downloadManager?.cancelDownload(id: id)
        Log.download.info("Cancelled download: \(id)")
    }

    /// Retries a failed download for the given model.
    ///
    /// Delegates to ``BackgroundDownloadManager/retryDownload(id:)``, which resumes
    /// from the previously-downloaded bytes when resume data is available, or falls
    /// back to a fresh download transparently when the server rejects stale data.
    public func retryDownload(for model: DownloadableModel) {
        guard let manager = downloadManager else {
            searchError = "Download manager is not available yet."
            return
        }

        Task {
            await manager.retryDownload(id: model.id)
            trackedDownloads[model.id] = manager.activeDownloads[model.id]
            startDownloadSync()
        }
    }

    // MARK: - Local Model Management

    /// Deletes a downloaded model from disk.
    public func deleteModel(_ model: ModelInfo) throws {
        try modelStorage.deleteModel(model)
        // why: a delete changes what's on disk, so the discovery cache must be
        // refreshed. Previously the sheet's onAppear blanket-invalidated on every
        // open; now invalidation happens at the mutation point (#1774).
        invalidateModelCache()
        Log.download.info("Deleted model: \(model.name)")
    }

    /// Imports a local model file or directory into the app's models directory.
    @discardableResult
    public func importModel(from sourceURL: URL) throws -> ModelInfo {
        let destination = try modelStorage.importModel(from: sourceURL)

        if let imported = importedModel(at: destination) {
            invalidateModelCache()
            return imported
        }

        do {
            try fileRemover(destination)
        } catch {
            Log.ui.warning("Failed to clean up unsupported imported model at \(destination.path): \(error.localizedDescription)")
            diagnostics?.record(.modelFileDeletionFailed(destination, reason: error.localizedDescription))
        }
        throw ModelImportError.unsupportedFormat
    }

    // MARK: - Benchmark

    /// Runs a benchmark for the given model and stores the result in ``benchmarkResults``.
    ///
    /// The model must already be loaded in the relevant `InferenceService`. This method is
    /// a no-op when ``benchmarkRunner`` is `nil` or a benchmark is already in progress.
    public func runBenchmark(for model: ModelInfo) async {
        guard let runner = benchmarkRunner, !isBenchmarking else { return }
        isBenchmarking = true
        defer { isBenchmarking = false }
        do {
            let result = try await runner.runBenchmark(for: model)
            benchmarkResults[model.fileName] = result
            Log.inference.info("Benchmark complete for \(model.name): \(result.tier.label)")
            if let cache = benchmarkCache {
                do {
                    try await cache.upsert(modelFileName: model.fileName, result: result)
                } catch {
                    Log.persistence.warning("Failed to persist benchmark result for \(model.name): \(error.localizedDescription)")
                    diagnostics?.record(.benchmarkCacheUnavailable(reason: error.localizedDescription))
                }
            }
        } catch {
            Log.inference.error("Benchmark failed for \(model.name): \(error)")
        }
    }

    private func loadCachedBenchmarkResults() {
        guard let cache = benchmarkCache else { return }
        Task { [weak self] in
            do {
                let entries = try await cache.fetchAll()
                guard let self else { return }
                for (fileName, result) in entries {
                    self.benchmarkResults[fileName] = result
                }
            } catch {
                Log.persistence.warning("Failed to load cached benchmark results: \(error.localizedDescription)")
                self?.diagnostics?.record(.benchmarkCacheUnavailable(reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Device Capability Queries

    /// Whether this device has enough RAM to run a model of the given size.
    ///
    /// Pre-download recommendation only — backed by `ModelLoadPlan.canRunModel`. Load-time
    /// gating uses the full plan computation with the active backend's memory strategy.
    public func canRunModel(sizeBytes: UInt64) -> Bool {
        ModelLoadPlan.canRunModel(
            sizeBytes: sizeBytes,
            physicalMemoryBytes: deviceCapability.physicalMemory
        )
    }

    /// Whether there is insufficient free disk space to download this model.
    ///
    /// Returns `true` when `model.sizeBytes > 0` and the volume's available capacity
    /// for important usage is a positive value less than `model.sizeBytes`. Returns
    /// `false` when the size is unknown (`sizeBytes == 0`), the volume reports a
    /// non-positive / missing capacity (e.g. CI runners and some sandboxed mounts
    /// return 0 for `volumeAvailableCapacityForImportantUsageKey`), or any filesystem
    /// query error — so the download button is not blocked unnecessarily.
    public func diskSpaceInsufficient(for model: DownloadableModel) -> Bool {
        guard model.sizeBytes > 0 else { return false }
        do {
            let values = try URL.documentsDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            // `volumeAvailableCapacityForImportantUsage` can be `nil` on volumes that
            // don't support the importance heuristic, and is reported as `0` on some
            // hosted/ephemeral filesystems (notably GitHub macOS runners). Treat both
            // as "unknown" rather than "zero free bytes" — otherwise even a 1-byte
            // download would be blocked.
            guard let available = values.volumeAvailableCapacityForImportantUsage,
                  available > 0 else {
                Log.download.warning("Disk space query returned non-positive capacity; treating as sufficient")
                return false
            }
            return UInt64(available) < model.sizeBytes
        } catch {
            Log.download.warning("Disk space query failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Exposes the underlying `DeviceCapabilityService` for use by views that need
    /// to compute per-variant recommendations (e.g., `ModelDownloadTab`).
    var deviceCapabilityService: DeviceCapabilityService {
        deviceCapability
    }

    /// Compatibility tier for sorting a group by device fit (lower = better).
    ///
    /// - 0: at least one variant comfortably fits
    /// - 1: at least one variant borderline fits (passes at 80% of declared size)
    /// - 2: all variants too large
    /// - 3: all variants have unknown size (`sizeBytes == 0`)
    public func compatibilityTier(for group: DownloadableModelGroup) -> Int {
        let sized = group.variants.filter { $0.sizeBytes > 0 }
        guard !sized.isEmpty else { return 3 }

        let physical = deviceCapability.physicalMemory
        if sized.contains(where: { ModelLoadPlan.canRunModel(sizeBytes: $0.sizeBytes, physicalMemoryBytes: physical) }) {
            return 0
        }
        if sized.contains(where: { ModelLoadPlan.canRunModel(sizeBytes: $0.sizeBytes * 80 / 100, physicalMemoryBytes: physical) }) {
            return 1
        }
        return 2
    }

    /// Ranks the current `searchResults` by composite model-fit score for a use case.
    ///
    /// Additive helper that layers `ModelFitScorer` (quality / speed / fit / context)
    /// over the existing browse results. It does NOT alter `compatibilityTier(for:)` or
    /// the default group sort — the authoritative will-it-run gate stays `ModelLoadPlan`.
    /// Returns best-first.
    ///
    /// - Parameters:
    ///   - useCase: The use case to weight dimensions for. Defaults to `selectedUseCase`.
    ///   - device: Device profile for scoring. Defaults to the real host profile; tests
    ///     inject a fixed profile so ranking is deterministic regardless of the runner.
    public func rankedVariants(
        useCase: ModelUseCase? = nil,
        device: DeviceProfile? = nil
    ) -> [(DownloadableModel, ModelFitScore)] {
        let resolvedDevice = device ?? DeviceProfile(
            physicalMemoryBytes: deviceCapability.physicalMemory,
            usableMemoryBytes: DeviceCapabilityService.queryAvailableMemory(),
            memoryBandwidthGBs: AppleSiliconBandwidth.estimatedBandwidthGBs()
        )
        return ModelFitScorer().rank(searchResults, useCase: useCase ?? selectedUseCase, device: resolvedDevice)
    }

    /// The single highest-fit model for this device under the current selection,
    /// or `nil` when there is nothing to rank yet.
    ///
    /// Highlights one model in the browser as "recommended for your device": it is
    /// the top of ``rankedVariants(useCase:device:)`` restricted to candidates that
    /// will actually run (`willRun`). Additive and read-only — it does not reorder
    /// or filter `searchResults`; the row UI simply badges the returned model.
    ///
    /// Ranks `searchResults` when a search is active, otherwise the device-tier
    /// `recommendedModels` (curated) list, so a fresh browser with no query still
    /// surfaces a pick. Returns `nil` if neither list has a runnable candidate.
    ///
    /// - Parameters:
    ///   - useCase: Use case to weight dimensions for. Defaults to `selectedUseCase`.
    ///   - device: Device profile for scoring. Defaults to the real host profile;
    ///     tests inject a fixed profile for deterministic ranking.
    public func recommendedModel(
        useCase: ModelUseCase? = nil,
        device: DeviceProfile? = nil
    ) -> DownloadableModel? {
        let resolvedDevice = device ?? DeviceProfile(
            physicalMemoryBytes: deviceCapability.physicalMemory,
            usableMemoryBytes: DeviceCapabilityService.queryAvailableMemory(),
            memoryBandwidthGBs: AppleSiliconBandwidth.estimatedBandwidthGBs()
        )
        let pool = searchResults.isEmpty ? recommendedModels : searchResults
        guard !pool.isEmpty else { return nil }
        let ranked = ModelFitScorer().rank(
            pool,
            useCase: useCase ?? selectedUseCase,
            device: resolvedDevice
        )
        return ranked.first(where: { $0.1.willRun })?.0
    }

    /// The fit score for a single downloadable model under the current selection.
    ///
    /// Lets the row UI show a `SpeedClass` badge / `rationale` without re-ranking the
    /// whole list. Returns `nil` for unscoreable (size 0) models. `device` is injectable
    /// for deterministic tests; production passes `nil` for the real host profile.
    public func fitScore(
        for model: DownloadableModel,
        useCase: ModelUseCase? = nil,
        device: DeviceProfile? = nil
    ) -> ModelFitScore? {
        let resolvedDevice = device ?? DeviceProfile(
            physicalMemoryBytes: deviceCapability.physicalMemory,
            usableMemoryBytes: DeviceCapabilityService.queryAvailableMemory(),
            memoryBandwidthGBs: AppleSiliconBandwidth.estimatedBandwidthGBs()
        )
        return ModelFitScorer().score(model, useCase: useCase ?? selectedUseCase, device: resolvedDevice)
    }

    // MARK: - Use-case persistence

    /// Restores `selectedUseCase` from the injected defaults store, if any.
    ///
    /// Sets the backing value directly to avoid re-triggering `persistSelectedUseCase`
    /// during init (a no-op write, but pointless churn).
    private func restoreSelectedUseCase() {
        guard let userDefaults,
              let raw = userDefaults.string(forKey: Self.selectedUseCaseKey),
              let restored = ModelUseCase(rawValue: raw) else { return }
        // Assigning here fires didSet → persistSelectedUseCase, which writes back the
        // same value. Harmless and keeps the property a plain stored var.
        selectedUseCase = restored
    }

    /// Persists `selectedUseCase` when a defaults store was injected; otherwise no-op.
    private func persistSelectedUseCase() {
        userDefaults?.set(selectedUseCase.rawValue, forKey: Self.selectedUseCaseKey)
    }

    /// Whether a downloadable model's file already exists on disk.
    ///
    /// Uses a cached snapshot of discovered models to avoid repeated filesystem scans.
    /// Call `invalidateModelCache()` after downloads complete or models are deleted.
    public func isModelDownloaded(_ model: DownloadableModel) -> Bool {
        if discoveredModelFileNames == nil {
            discoveredModelFileNames = Set(modelStorage.discoverModels().map(\.fileName))
        }
        return discoveredModelFileNames?.contains(model.fileName) ?? false
    }

    /// Invalidates the cached model discovery results, forcing a fresh filesystem scan
    /// on the next `isModelDownloaded` call.
    ///
    /// Also removes any `.failed` or `.cancelled` entries from `trackedDownloads`
    /// immediately, since a cache reset signals a state change (e.g. download complete
    /// or cancelled) and stale terminal rows should not persist across resets.
    public func invalidateModelCache() {
        discoveredModelFileNames = nil
        trackedDownloads = trackedDownloads.filter { _, state in
            switch state.status {
            case .failed, .cancelled: return false
            default: return true
            }
        }
        // why: invalidation signals a disk mutation (download finished, delete,
        // cancel). Drive a fresh off-main scan so the cached discoveredModels /
        // totalStorageUsed snapshot reflects the new on-disk state without a
        // render-path scan (#1787). Force-refresh because the cached snapshot is
        // known stale and a coincidentally in-flight scan may predate the mutation.
        forceRefreshDiscoveredModels()
    }

    /// Returns the active download state for a model, if any.
    public func downloadState(for model: DownloadableModel) -> DownloadState? {
        activeDownloads[model.id]
    }

    private func importedModel(at url: URL) -> ModelInfo? {
        if let gguf = ModelInfo(ggufURL: url) {
            return gguf
        }

        if let mlx = ModelInfo(mlxDirectory: url) {
            return mlx
        }

        return nil
    }
}
