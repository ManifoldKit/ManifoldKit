import Foundation

/// Live in-memory registry of locally-discoverable ``ModelInfo`` values.
///
/// `ModelRegistry` is the focused dependency that the model-management UI
/// (`ModelManagementSheet`, `HuggingFaceBrowserView`, `StorageManagementView`,
/// etc.) reads from instead of pulling the entire ``ChatViewModel`` from
/// the environment. It owns three pieces of state:
///
/// - ``availableModels`` — the discovered list, refreshed on demand.
/// - ``selectedModel`` — the user's current selection, two-way bound from the
///   model-management UI.
/// - ``compatibility(for:)`` — the per-``ModelType`` capability query that
///   used to live on `ChatViewModel.inferenceService`.
///
/// `ChatViewModel` constructs and owns one of these and forwards its existing
/// `availableModels` / `selectedModel` / `refreshModels()` API into it. Hosts
/// that build their own UI around `ChatViewModel` keep using the existing
/// surface; new explicit-init view sites take a `ModelRegistry` directly.
///
/// The name is deliberately distinct from the future `ModelCatalog` (a
/// persisted on-disk metadata sidecar). Registry = live, in-memory; catalog
/// = durable, indexed.
@Observable
@MainActor
public final class ModelRegistry {

    // MARK: - State

    /// All models discovered on disk, plus the built-in Foundation model when
    /// available. Refreshed by ``refresh()``.
    public var availableModels: [ModelInfo] = []

    /// The model the user has selected. Setting this from the UI drives
    /// downstream load coordination through `ChatViewModel`.
    public var selectedModel: ModelInfo?

    /// Files that failed to load during the last ``refresh()`` call, surfaced
    /// alongside ``ModelDiscoveryError`` so the model-management UI can show a
    /// banner like "Skipped: foo.gguf — file is not a valid GGUF" instead of
    /// silently dropping the entry. Cleared at the start of every refresh.
    public var lastDiscoveryErrors: [ModelDiscoveryError] = []

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private let modelStorage: ModelStorageService

    /// Optional provider for "is the Foundation model available on this
    /// device?" — when present and returning `true`, ``refresh()`` prepends
    /// ``ModelInfo/builtInFoundation`` to the discovered list. `ChatViewModel`
    /// wires its existing `foundationModelProvider` closure here.
    @ObservationIgnored
    public var foundationModelProvider: (@MainActor () -> Bool)?

    // MARK: - Init

    /// Constructs a registry over the supplied inference and storage services.
    ///
    /// - Parameters:
    ///   - inferenceService: The shared inference service. Used for the
    ///     per-``ModelType`` compatibility query.
    ///   - modelStorage: Backing store for on-disk model discovery.
    ///   - foundationModelProvider: Optional closure reporting whether the
    ///     built-in Foundation model is available. Hosts typically wire
    ///     `{ FoundationBackend.isAvailable }` here.
    public init(
        inferenceService: InferenceService,
        modelStorage: ModelStorageService,
        foundationModelProvider: (@MainActor () -> Bool)? = nil
    ) {
        self.inferenceService = inferenceService
        self.modelStorage = modelStorage
        self.foundationModelProvider = foundationModelProvider
    }

    // MARK: - Discovery

    /// Re-scans the models directory and rebuilds ``availableModels``.
    ///
    /// Includes the built-in Foundation model when ``foundationModelProvider``
    /// returns `true`. Clears ``selectedModel`` if the previously selected
    /// model is no longer present.
    ///
    /// - Throws: A directory-creation error if the underlying models directory
    ///   could not be ensured. Callers that surface errors to the UI should
    ///   catch and forward; callers content with best-effort behaviour can
    ///   ignore via `try?`.
    public func refresh() throws {
        try modelStorage.ensureModelsDirectory()

        var models: [ModelInfo] = []
        var collectedErrors: [ModelDiscoveryError] = []
        if let provider = foundationModelProvider, provider() {
            models.append(.builtInFoundation)
        }
        let discovered = modelStorage.discoverModels(reportingErrors: { error in
            collectedErrors.append(error)
        })
        models.append(contentsOf: discovered)
        availableModels = models
        lastDiscoveryErrors = collectedErrors

        if let selected = selectedModel,
           !availableModels.contains(where: { $0.id == selected.id }) {
            selectedModel = nil
        }
    }

    // MARK: - Selection

    /// Canonical programmatic entry point for changing ``selectedModel``.
    ///
    /// Equivalent to assigning `selectedModel = model`, plus validation: the
    /// supplied model must already be in ``availableModels`` (or be
    /// ``ModelInfo/builtInFoundation``, which is always accepted because hosts
    /// may select it before a `refresh()` has populated the Foundation entry).
    /// `nil` is always accepted and clears the current selection.
    ///
    /// - Returns: `true` when the selection was accepted (and applied);
    ///   `false` when `model` is unknown to the registry — in which case the
    ///   previous selection is left in place.
    ///
    /// `selectedModel` remains writable so SwiftUI two-way bindings keep
    /// working; `selectModel(_:)` is the hook site for future logging,
    /// telemetry, and auto-load wiring.
    @discardableResult
    public func selectModel(_ model: ModelInfo?) -> Bool {
        // Hook site for future logging / validation / auto-load wiring.
        guard let model else {
            selectedModel = nil
            return true
        }
        if model.id == ModelInfo.builtInFoundation.id
            || availableModels.contains(where: { $0.id == model.id }) {
            selectedModel = model
            return true
        }
        return false
    }

    // MARK: - Compatibility

    /// Reports whether the supplied local model type has a registered backend.
    ///
    /// Forwards to ``InferenceService/compatibility(for:)``. Exposed here so
    /// model-management views can query compatibility without holding a
    /// reference to `InferenceService` (or, formerly, reaching into
    /// `ChatViewModel.inferenceService`).
    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        inferenceService.compatibility(for: modelType)
    }
}
