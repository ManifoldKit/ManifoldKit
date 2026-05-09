import Foundation

// MARK: - ModelCompatibilityResult

/// The result of a model-compatibility check against the active backend registry.
///
/// Use `InferenceService.compatibility(for:)` or the equivalent on `FrameworkCapabilityService`
/// to determine whether a model can be loaded before presenting it in the UI.
public enum ModelCompatibilityResult: Sendable, Equatable {
    /// The model type is handled by a registered backend.
    case supported

    /// No registered backend can handle this model type.
    ///
    /// `reason` is a short human-readable explanation suitable for a tooltip or
    /// subtitle label (e.g., "Requires the MLX backend, which is not enabled").
    case unsupported(reason: String)

    /// Whether this result indicates the model can be loaded.
    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// Human-readable explanation when unsupported, or `nil` when supported.
    public var unavailableReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

// MARK: - ModelTypeCompatibilityProvider

/// Implemented by any type that can report whether a given model type or API
/// provider is loadable in the current build/runtime.
///
/// `InferenceService` and `FrameworkCapabilityService` both conform so callers
/// can check compatibility through whichever handle they already hold.
///
/// Because both concrete implementations are `@MainActor`-isolated, the entire
/// protocol is declared `@MainActor` so callers obtain the correct isolation
/// guarantee and Swift's concurrency checker does not emit data-race warnings.
@MainActor
public protocol ModelTypeCompatibilityProvider: AnyObject {

    /// Returns whether the given local model type has a registered backend.
    func compatibility(for modelType: ModelType) -> ModelCompatibilityResult

    /// Returns whether the given API provider has a registered backend.
    func compatibility(for provider: APIProvider) -> ModelCompatibilityResult

    /// Convenience: returns `true` iff the backend for `modelType` is registered.
    func canLoad(modelType: ModelType) -> Bool

    /// Convenience: returns `true` iff the backend for `provider` is registered.
    func canLoad(provider: APIProvider) -> Bool

    /// Human-readable reason a model type is unavailable, or `nil` if supported.
    func unavailableReason(for modelType: ModelType) -> String?

    /// Human-readable reason an API provider is unavailable, or `nil` if supported.
    func unavailableReason(for provider: APIProvider) -> String?
}

// MARK: - Default implementations

extension ModelTypeCompatibilityProvider {

    public func canLoad(modelType: ModelType) -> Bool {
        compatibility(for: modelType).isSupported
    }

    public func canLoad(provider: APIProvider) -> Bool {
        compatibility(for: provider).isSupported
    }

    public func unavailableReason(for modelType: ModelType) -> String? {
        compatibility(for: modelType).unavailableReason
    }

    public func unavailableReason(for provider: APIProvider) -> String? {
        compatibility(for: provider).unavailableReason
    }
}
