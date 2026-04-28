import Foundation
import Observation

// MARK: - EnabledBackends

/// Describes which local model types and cloud providers are available in the
/// current build and on the current device.
///
/// Populated by `DefaultBackends.register(with:)` and exposed through
/// `FrameworkCapabilityService` so host apps can inspect backend availability
/// without importing `BaseChatBackends` directly.
public struct EnabledBackends: Sendable, Equatable {

    /// Local model types for which a backend factory was registered.
    public let localModelTypes: Set<ModelType>

    /// Cloud API providers for which a backend factory was registered.
    public let cloudProviders: Set<APIProvider>

    /// Whether the GGUF / llama.cpp backend is available.
    public var supportsGGUF: Bool { localModelTypes.contains(.gguf) }

    /// Whether the MLX backend is available.
    public var supportsMLX: Bool { localModelTypes.contains(.mlx) }

    /// Whether the Apple Foundation Models backend is available.
    public var supportsFoundation: Bool { localModelTypes.contains(.foundation) }

    /// Whether any local on-device inference backend is available.
    public var supportsLocalInference: Bool { !localModelTypes.isEmpty }

    /// Whether any cloud API backend is available.
    public var supportsCloudInference: Bool { !cloudProviders.isEmpty }

    public init(
        localModelTypes: Set<ModelType> = [],
        cloudProviders: Set<APIProvider> = []
    ) {
        self.localModelTypes = localModelTypes
        self.cloudProviders = cloudProviders
    }
}

// MARK: - FrameworkCapabilityService

/// A single, observable service that exposes framework settings and runtime
/// backend capabilities to the host application.
///
/// This is the primary touchpoint for host apps that need to:
/// - Query which model types or API providers are available (before load)
/// - Observe enabled backends and feature flags reactively
/// - Provide framework-level capability information to UI layers
///
/// Instantiate once and inject via `@Environment`:
///
/// ```swift
/// let capabilityService = FrameworkCapabilityService(inferenceService: inferenceService)
/// // …
/// SomeView()
///     .environment(capabilityService)
/// ```
///
/// The service is thread-safe. Observable properties are updated on the main actor.
@Observable
@MainActor
public final class FrameworkCapabilityService {

    // MARK: - Observable State

    /// Backends compiled into this binary, independent of whether they have
    /// been registered on the backing `InferenceService` yet.
    public let compiledBackends: CompiledBackends

    /// Describes which backends are registered and available in this build.
    ///
    /// Updated whenever `refresh()` is called (typically after backend registration).
    public private(set) var enabledBackends: EnabledBackends

    // MARK: - Private

    private let inferenceService: InferenceService

    // MARK: - Init

    /// Creates a capability service backed by the given inference service.
    ///
    /// Call `refresh()` after registering backends with the inference service
    /// to populate `enabledBackends`.
    public init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
        self.compiledBackends = .current
        // Start with an empty snapshot; caller invokes refresh() after backend registration.
        self.enabledBackends = EnabledBackends()
    }

    // MARK: - Refresh

    /// Snapshots the currently registered backends from the inference service.
    ///
    /// Call this once after `DefaultBackends.register(with:)` returns so that
    /// `enabledBackends` reflects the actual registered state.
    public func refresh() {
        enabledBackends = inferenceService.registeredBackendSnapshot()
    }

    // MARK: - Compatibility Queries

    /// Returns whether the given local model type has a registered backend.
    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        inferenceService.compatibility(for: modelType)
    }

    /// Returns whether the given API provider has a registered backend.
    public func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        inferenceService.compatibility(for: provider)
    }

    /// Returns `true` iff a backend for the given local model type is registered.
    public func canLoad(modelType: ModelType) -> Bool {
        inferenceService.canLoad(modelType: modelType)
    }

    /// Returns `true` iff a backend for the given API provider is registered.
    public func canLoad(provider: APIProvider) -> Bool {
        inferenceService.canLoad(provider: provider)
    }

    /// Human-readable reason a model type is unavailable, or `nil` if supported.
    public func unavailableReason(for modelType: ModelType) -> String? {
        inferenceService.unavailableReason(for: modelType)
    }

    /// Human-readable reason an API provider is unavailable, or `nil` if supported.
    public func unavailableReason(for provider: APIProvider) -> String? {
        inferenceService.unavailableReason(for: provider)
    }
}
