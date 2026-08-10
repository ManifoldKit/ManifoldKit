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
public struct ImageGenerationConfigSnapshot: Sendable, Hashable {

    /// Mirrors ``ImageGenerationConfig/steps``. `nil` means the backend
    /// resolved its own preset default at generation time rather than a
    /// caller-supplied value — persisted as-is so a "regenerate with the
    /// same settings" replay re-resolves the preset rather than baking in
    /// whatever number happened to be in effect at capture time.
    public var steps: Int?
    public var width: Int
    public var height: Int
    public var seed: UInt64?
    public var guidanceScale: Float?
    /// Mirrors ``ImageGenerationConfig/aspectRatio``. `nil` means the backend
    /// derives the ratio from ``width``/``height`` or uses its own default.
    public var aspectRatio: String?

    /// Mirrors ``ImageGenerationConfig/outputDirectory``. Persisted so a
    /// "regenerate from history" affordance can re-target the same storage
    /// container the original generation used. `nil` rehydrates as
    /// "backend's discretion" on replay.
    public var outputDirectory: URL?

    /// `CGSize`-shaped accessor for ``width`` × ``height``. The persisted
    /// fields stay primitive integers so this type auto-synthesises
    /// `Codable` and `Hashable` on every platform — `CGSize` does not carry
    /// those conformances on Linux.
    public var resolution: CGSize {
        get { CGSize(width: Double(width), height: Double(height)) }
        set {
            // Round (not truncate); see ``ImageGenerationConfig/resolution``
            // for rationale.
            width = Int(newValue.width.rounded())
            height = Int(newValue.height.rounded())
        }
    }

    public init(
        steps: Int?,
        width: Int,
        height: Int,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil,
        aspectRatio: String? = nil,
        outputDirectory: URL? = nil
    ) {
        self.steps = steps
        self.width = width
        self.height = height
        self.seed = seed
        self.guidanceScale = guidanceScale
        self.aspectRatio = aspectRatio
        self.outputDirectory = outputDirectory
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
        self.aspectRatio = config.aspectRatio
        self.outputDirectory = config.outputDirectory
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
            guidanceScale: guidanceScale,
            aspectRatio: aspectRatio,
            outputDirectory: outputDirectory
        )
    }
}

// MARK: - Codable

extension ImageGenerationConfigSnapshot: Codable {

    // Custom Codable so older persisted rows that pre-date `outputDirectory`
    // decode to `nil` rather than failing the whole row, and so absent
    // fields never get force-encoded as `null`.
    private enum CodingKeys: String, CodingKey {
        case steps, width, height, seed, guidanceScale, aspectRatio, outputDirectory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An older persisted row still carries an explicit `steps` integer —
        // decode it as present so pre-optional rows round-trip. A new row
        // omits the key entirely when `steps` is `nil`.
        self.steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        self.guidanceScale = try c.decodeIfPresent(Float.self, forKey: .guidanceScale)
        self.aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)
        self.outputDirectory = try c.decodeIfPresent(URL.self, forKey: .outputDirectory)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(steps, forKey: .steps)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(guidanceScale, forKey: .guidanceScale)
        try c.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
    }
}
