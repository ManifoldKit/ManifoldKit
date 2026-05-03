import Foundation
import CoreFoundation

/// Persistence-layer mirror of ``ImageGenerationConfig``.
///
/// Held by ``ImageMessagePayload`` so saved conversation history can render —
/// or regenerate — an image with the exact parameters that produced it.
///
/// ## Why a separate type?
///
/// ``ImageGenerationConfig`` is the *runtime* shape. Backends read fields
/// from it and may grow new ones over time. Decoupling persistence from
/// runtime keeps two concerns from drifting into each other:
///
/// - Adding a new runtime knob (e.g. a future scheduler-selection field)
///   does not silently change the on-disk wire format of every persisted
///   image message.
/// - Renaming or restructuring a runtime field does not strand persisted
///   rows; the snapshot type stays stable and adopts changes deliberately
///   via an explicit Codable migration.
///
/// Mirrors the field shape exactly today; future divergence (e.g. dropping
/// fields the persistence layer doesn't need, or adding fields that capture
/// runtime-only state at the moment of generation) is allowed without
/// touching ``ImageGenerationConfig``.
public struct ImageGenerationConfigSnapshot: Sendable, Codable, Hashable {

    public var steps: Int
    public var width: Int
    public var height: Int
    public var seed: UInt64?
    public var guidanceScale: Float?

    /// `CGSize`-shaped accessor for ``width`` × ``height``. The persisted
    /// fields stay primitive integers so this type auto-synthesises
    /// `Codable` and `Hashable` on every platform — `CGSize` does not carry
    /// those conformances on Linux.
    public var resolution: CGSize {
        get { CGSize(width: Double(width), height: Double(height)) }
        set {
            width = Int(newValue.width)
            height = Int(newValue.height)
        }
    }

    public init(
        steps: Int,
        width: Int,
        height: Int,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil
    ) {
        self.steps = steps
        self.width = width
        self.height = height
        self.seed = seed
        self.guidanceScale = guidanceScale
    }

    /// Captures the current runtime configuration into a persistable
    /// snapshot. Used by the persistence layer at the moment a
    /// ``ImageMessagePayload`` is created.
    public init(from config: ImageGenerationConfig) {
        self.steps = config.steps
        self.width = config.width
        self.height = config.height
        self.seed = config.seed
        self.guidanceScale = config.guidanceScale
    }

    /// Rehydrates a runtime ``ImageGenerationConfig`` from this snapshot.
    /// Used when replaying a generation from history (e.g. a "regenerate
    /// with the same settings" affordance).
    public func toConfig() -> ImageGenerationConfig {
        ImageGenerationConfig(
            steps: steps,
            width: width,
            height: height,
            seed: seed,
            guidanceScale: guidanceScale
        )
    }
}
