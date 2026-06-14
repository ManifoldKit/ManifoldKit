import Foundation
import Observation
// @_spi(BackendInternals): the fit bridge reuses ManifoldHardware primitives
// (DeviceProfile, ModelLoadPlan.Environment) the same way the scorer does.
@_spi(BackendInternals) import ManifoldHardware

// MARK: - ModelSelectionSortOrder

/// Ordering options for a model-selection list.
///
/// Hoisted out of `ModelSelectionTabView` (the bundled picker) so headless
/// consumers can sort the model list as **data** without importing any UI
/// module. `ModelPicker` (the sample view) reads the same enum.
public enum ModelSelectionSortOrder: String, CaseIterable, Identifiable, Sendable {
    case alphabetical = "Alphabetical"
    case type = "Type"
    case size = "Size (Smallest First)"
    case capability = "Capability / Speed"

    public var id: Self { self }
}

// MARK: - ModelSelectionGroup

/// A semantic grouping of the selectable model list.
///
/// fireside-night and offgrid-ai both rebuilt this fork (Apple Foundation model
/// vs. on-disk downloads) by hand. `ModelSelection` vends it as data.
public enum ModelSelectionGroup: String, Sendable, CaseIterable, Identifiable {
    /// The OS-resident Apple Foundation model (always first when present).
    case foundation
    /// Models the user has downloaded to disk (GGUF / MLX).
    case downloaded

    public var id: Self { self }

    /// A short human-readable section title.
    public var title: String {
        switch self {
        case .foundation: return "Apple Intelligence"
        case .downloaded: return "Downloaded Models"
        }
    }
}

// MARK: - ScoredModel

/// A model paired with its computed device-fit score (when scoreable).
///
/// `score` is `nil` for entries the fit bridge cannot rank (e.g. a 0-byte
/// non-foundation file). Consumers can still render an unscored model.
public struct ScoredModel: Identifiable, Sendable {
    public let model: ModelInfo
    public let score: ModelFitScore?

    public var id: UUID { model.id }

    public init(model: ModelInfo, score: ModelFitScore?) {
        self.model = model
        self.score = score
    }
}

// MARK: - ModelSelecting

/// The headless selection seam consumers mock against.
///
/// offgrid-ai re-wrapped MK's selection behind its own protocol because nothing
/// public existed. `ModelSelecting` is that surface: the sorted / grouped /
/// scored list as data, the current selection, the device recommendation, and a
/// synchronous auto-load entry point — no chat, no UI.
@MainActor
public protocol ModelSelecting: AnyObject {
    /// All selectable models, unsorted (as the registry discovered them).
    var availableModels: [ModelInfo] { get }

    /// The current selection. Setting it routes through ``select(_:)``.
    var selectedModel: ModelInfo? { get set }

    /// The device's recommended model size tier (for "Recommended" badges).
    var recommendedSize: ModelSizeRecommendation { get }

    /// The models sorted by the supplied order.
    func sortedModels(by order: ModelSelectionSortOrder) -> [ModelInfo]

    /// The models split into foundation / downloaded sections, each sorted.
    func groupedModels(by order: ModelSelectionSortOrder) -> [(group: ModelSelectionGroup, models: [ModelInfo])]

    /// The models scored against the device for the given use case, best-first.
    func scoredModels(useCase: ModelUseCase) -> [ScoredModel]

    /// Selects a model. Returns `false` when the model is unknown to the
    /// underlying registry (selection unchanged). Mirrors
    /// ``ModelRegistry/selectModel(_:)``.
    @discardableResult
    func select(_ model: ModelInfo?) -> Bool

    /// Synchronously dispatches a load of the current selection into the shared
    /// coordinator. Observe progress via ``loadStatusUpdates()``.
    func loadSelected()

    /// A fresh `AsyncStream` of load-status transitions for this surface.
    func loadStatusUpdates() -> AsyncStream<ModelLoadStatus>
}

// MARK: - ModelSelection

/// Headless model selection + load — the product of Option B.
///
/// `ModelSelection` lets a consumer choose and load a model **without** standing
/// up a `ChatViewModel`. idlewick spun up a whole chat view model purely to load
/// a model for its NPC runner; fireside-night and offgrid-ai rebuilt the grouped
/// picker and re-derived device-fit/capability logic MK already owns. This type
/// composes the pieces MK already has:
///
/// - ``ModelRegistry`` for selection state + the synchronous `selectModel`
///   entry (which now performs the #1312 endpoint-clear in its setter).
/// - The `ModelInfo → ModelFitScore` bridge + ``DeviceCapabilityService`` for
///   the recommendation surface (sorted / scored data).
/// - The **shared**, service-vended ``ModelLoadCoordinator`` — one coordinator
///   per `InferenceService` (Correction E). A headless surface and a chat view
///   model over the same service share this instance so a headless load does
///   **not** leak progress into the chat phase: chat-only side effects ride the
///   coordinator's callback seams (installed by `ChatViewModel`), while the
///   shared progress/phase/error path fans out through per-observer
///   `AsyncStream`s (``loadStatusUpdates()``).
///
/// The sorted / scored / grouped list is the real deliverable; auto-load is a
/// single synchronous `@MainActor` call into the shared coordinator.
@Observable
@MainActor
public final class ModelSelection: ModelSelecting {

    // MARK: - Dependencies

    /// `internal` (not `private`) so `@testable` characterization tests can seed
    /// the registry's `availableModels` without a filesystem scan. Not part of
    /// the public surface.
    let registry: ModelRegistry
    private let coordinator: ModelLoadCoordinator
    private let deviceCapability: DeviceCapabilityService
    private let device: DeviceProfile

    // MARK: - Init

    /// Builds a selection surface over a shared inference service.
    ///
    /// - Parameters:
    ///   - inferenceService: The shared service. ``ModelLoadCoordinator`` is
    ///     taken from `inferenceService.modelLoadCoordinator` so this surface and
    ///     any sibling `ChatViewModel` share one coordinator (Correction E).
    ///   - modelStorage: Backing store for on-disk discovery.
    ///   - deviceCapability: Device-fit recommendation source.
    ///   - foundationModelProvider: Optional "is the Foundation model available?"
    ///     probe; forwarded to the registry.
    ///   - device: Device profile for fit scoring (injectable for tests).
    public init(
        inferenceService: InferenceService,
        modelStorage: ModelStorageService = ModelStorageService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        foundationModelProvider: (@MainActor () -> Bool)? = nil,
        device: DeviceProfile = .current
    ) {
        self.registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage,
            foundationModelProvider: foundationModelProvider
        )
        self.coordinator = inferenceService.modelLoadCoordinator
        self.deviceCapability = deviceCapability
        self.device = device
    }

    /// Builds a selection surface over a registry the host already constructed.
    ///
    /// Use this when a `ChatViewModel` and a `ModelSelection` must share the same
    /// ``ModelRegistry`` instance (so selecting in one is visible in the other),
    /// passing `chatViewModel.modelRegistry` and the service's coordinator.
    public init(
        registry: ModelRegistry,
        coordinator: ModelLoadCoordinator,
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        device: DeviceProfile = .current
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.deviceCapability = deviceCapability
        self.device = device
    }

    // MARK: - Discovery

    /// Re-scans the models directory and rebuilds ``availableModels``.
    public func refresh() throws {
        try registry.refresh()
    }

    /// Off-main discovery; mirrors ``ModelRegistry/refreshAsync()``.
    public func refreshAsync() async throws {
        try await registry.refreshAsync()
    }

    // MARK: - ModelSelecting

    public var availableModels: [ModelInfo] {
        registry.availableModels
    }

    public var selectedModel: ModelInfo? {
        get { registry.selectedModel }
        set { registry.selectedModel = newValue }
    }

    public var recommendedSize: ModelSizeRecommendation {
        deviceCapability.recommendedModelSize()
    }

    public func sortedModels(by order: ModelSelectionSortOrder) -> [ModelInfo] {
        Self.sortModels(registry.availableModels, by: order)
    }

    public func groupedModels(
        by order: ModelSelectionSortOrder
    ) -> [(group: ModelSelectionGroup, models: [ModelInfo])] {
        Self.groupModels(registry.availableModels, by: order)
    }

    public func scoredModels(useCase: ModelUseCase) -> [ScoredModel] {
        let scorer = ModelFitScorer()
        // Preserve registry order; attach a score where one can be computed.
        return registry.availableModels.map { model in
            ScoredModel(
                model: model,
                score: scorer.score(model, useCase: useCase, device: device)
            )
        }
    }

    /// Ranks scoreable models best-first under a use case (drops unscoreable).
    public func rankedModels(useCase: ModelUseCase) -> [ScoredModel] {
        let scorer = ModelFitScorer()
        return scorer.rank(registry.availableModels, useCase: useCase, device: device)
            .map { ScoredModel(model: $0.0, score: $0.1) }
    }

    @discardableResult
    public func select(_ model: ModelInfo?) -> Bool {
        registry.selectModel(model)
    }

    /// Synchronously dispatches a load of the current selection (latest-wins).
    ///
    /// Resolves the current ``selectedModel`` into a ``LoadIntent`` and hands it
    /// to the shared coordinator. The newest dispatch always wins. No-op when no
    /// model is selected. The endpoint case is owned by chat hosts; a headless
    /// selection surface drives local/foundation models.
    public func loadSelected() {
        guard let model = registry.selectedModel else { return }
        // drivesChatSeams: false — a headless load must not push a sibling
        // ChatViewModel into a `.modelLoading` phase or write its errorMessage.
        // This surface observes progress via `loadStatusUpdates()` instead.
        coordinator.dispatchLoad(.localModel(model), drivesChatSeams: false)
    }

    public func loadStatusUpdates() -> AsyncStream<ModelLoadStatus> {
        coordinator.statusUpdates()
    }

    // MARK: - Sorting (hoisted from ModelSelectionTabView)

    /// Sorts models by the requested order.
    ///
    /// Relocated verbatim from `ModelSelectionTabView.sortModels(_:by:)` (the
    /// only truly view-trapped piece) so headless consumers and the sample
    /// picker share one ordering implementation.
    public static func sortModels(
        _ models: [ModelInfo],
        by order: ModelSelectionSortOrder
    ) -> [ModelInfo] {
        models.sorted { lhs, rhs in
            switch order {
            case .alphabetical:
                return compareNames(lhs, rhs)

            case .type:
                let lhsRank = typeSortRank(for: lhs.modelType)
                let rhsRank = typeSortRank(for: rhs.modelType)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return compareNames(lhs, rhs)

            case .size:
                if lhs.fileSize != rhs.fileSize {
                    return lhs.fileSize < rhs.fileSize
                }
                return compareNames(lhs, rhs)

            case .capability:
                let lhsTier = lhs.effectiveCapabilityTier.rawValue
                let rhsTier = rhs.effectiveCapabilityTier.rawValue
                if lhsTier != rhsTier {
                    return lhsTier > rhsTier
                }
                if lhs.fileSize != rhs.fileSize {
                    return lhs.fileSize < rhs.fileSize
                }
                return compareNames(lhs, rhs)
            }
        }
    }

    /// Splits a model list into foundation / downloaded sections, each sorted
    /// by `order`. Empty sections are omitted.
    ///
    /// Static so the bundled `ModelPicker` sample view can render the same
    /// grouped data the headless instance method vends, without holding a live
    /// `ModelSelection` (and therefore a `ModelLoadCoordinator`) — the sample
    /// view drives selection through a `ModelRegistry` it already owns. The
    /// instance ``groupedModels(by:)`` forwards here so both paths share one
    /// grouping implementation.
    public static func groupModels(
        _ models: [ModelInfo],
        by order: ModelSelectionSortOrder
    ) -> [(group: ModelSelectionGroup, models: [ModelInfo])] {
        let sorted = sortModels(models, by: order)
        let foundation = sorted.filter { $0.modelType == .foundation }
        let downloaded = sorted.filter { $0.modelType != .foundation }
        var groups: [(group: ModelSelectionGroup, models: [ModelInfo])] = []
        if !foundation.isEmpty {
            groups.append((.foundation, foundation))
        }
        if !downloaded.isEmpty {
            groups.append((.downloaded, downloaded))
        }
        return groups
    }

    private static func compareNames(_ lhs: ModelInfo, _ rhs: ModelInfo) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func typeSortRank(for type: ModelType) -> Int {
        BackendDescriptorRegistry.shared.descriptor(for: type)?.sortOrder ?? Int.max
    }
}
