import Foundation
import CoreFoundation

/// Sampling and diffusion parameters shared across on-device image generation
/// backends.
///
/// Mirrors the role ``GenerationConfig`` plays for text inference: a single
/// value type the caller hands to ``ImageGenerationBackend/generate(prompt:config:)``
/// so backends do not have to invent their own per-request shape. Backends that
/// do not honour a specific field silently ignore it, matching the
/// ``GenerationConfig`` convention.
///
/// ## Snapshot vs. runtime
///
/// This is the *runtime* config. For persistence, use
/// ``ImageGenerationConfigSnapshot`` — a separate value type with the same
/// fields but no expectation that future runtime additions become wire-format
/// changes. See ``ImageGenerationConfigSnapshot`` for rationale.
public struct ImageGenerationConfig: Sendable, Codable, Equatable {

    /// Number of denoising steps the backend should run.
    ///
    /// Typical ranges: 1–4 for distilled models (FLUX Schnell, SDXL Turbo),
    /// 20–50 for full-precision diffusion. Backends that expose a fixed step
    /// count (e.g. distilled-only conformers) clamp to their supported range.
    public var steps: Int

    /// Target output width in pixels. See ``resolution`` for the
    /// `CGSize`-shaped accessor.
    public var width: Int

    /// Target output height in pixels. See ``resolution`` for the
    /// `CGSize`-shaped accessor.
    public var height: Int

    /// Target output resolution in pixels.
    ///
    /// Stored as separate ``width``/``height`` fields so this type
    /// auto-synthesises `Codable` / `Equatable` on every platform — `CGSize`
    /// does not carry those conformances on Linux. Backends with a
    /// constrained native resolution (e.g. SDXL 1024×1024) either round to
    /// the closest supported size or surface a backend-level error — they
    /// MUST NOT silently scale.
    public var resolution: CGSize {
        get { CGSize(width: Double(width), height: Double(height)) }
        set {
            width = Int(newValue.width)
            height = Int(newValue.height)
        }
    }

    /// Deterministic sampling seed.
    ///
    /// When set, backends that expose a sampler seed initialise their RNG
    /// from this value so two runs with the same prompt and config produce
    /// the same image. Backends without a configurable seed silently ignore
    /// it. Stored as `UInt64` for parity with ``GenerationConfig/seed``.
    public var seed: UInt64?

    /// Classifier-free-guidance scale.
    ///
    /// Higher values push the model harder toward the prompt at the cost of
    /// fidelity. Typical range: 5.0–12.0 for SD/SDXL; distilled models often
    /// ignore this knob entirely. `nil` lets the backend apply its own
    /// default.
    public var guidanceScale: Float?

    public init(
        steps: Int = 20,
        width: Int = 1024,
        height: Int = 1024,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil
    ) {
        self.steps = steps
        self.width = width
        self.height = height
        self.seed = seed
        self.guidanceScale = guidanceScale
    }

    /// Convenience initializer that accepts a `CGSize`. Truncates to integer
    /// pixels — backends operate on whole-pixel resolutions, never fractions.
    public init(
        steps: Int = 20,
        resolution: CGSize,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil
    ) {
        self.init(
            steps: steps,
            width: Int(resolution.width),
            height: Int(resolution.height),
            seed: seed,
            guidanceScale: guidanceScale
        )
    }
}
