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
    /// `nil` (the default) means *backend's discretion* — the backend
    /// resolves the loaded model's own preset default rather than the
    /// caller guessing a number that fits every model. This matters because
    /// distilled models (SDXL Turbo, FLUX Schnell) are trained for 1–4
    /// steps; a caller-supplied default tuned for full diffusion (20–50)
    /// makes a distilled model run 5–20x more denoise work than it needs
    /// for no quality gain. Mirrors the ``GenerationConfig/maxThinkingTokens``
    /// precedent: `nil` defers to a model-aware default instead of the type
    /// hard-coding one value for every model shape.
    ///
    /// An explicit value always overrides the backend's preset and is
    /// clamped to whatever range that backend supports.
    public var steps: Int?

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
            // Round (not truncate) so `1023.7` becomes 1024, matching the
            // intuition that `CGSize` callers express logical pixel counts
            // rather than mathematically-floored values.
            width = Int(newValue.width.rounded())
            height = Int(newValue.height.rounded())
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

    /// Aspect ratio hint for backends that accept ratio strings rather than
    /// pixel dimensions (e.g. `"16:9"`, `"1:1"`, `"4:3"`).
    ///
    /// When non-nil, backends that support named ratios should use this value
    /// directly. `nil` means the backend uses its own default or derives the
    /// ratio from ``width`` / ``height``.
    public var aspectRatio: String?

    /// Destination directory the backend should write the produced image
    /// into.
    ///
    /// `nil` means *backend's discretion* — typically
    /// `FileManager.default.temporaryDirectory`. Specifying an explicit
    /// directory lets the host control the storage container (app-group
    /// sharing, backup exclusion, cleanup policy) without each backend
    /// inventing its own location convention. Backends MUST honour this
    /// value when set; the URL emitted by ``ImageGenerationEvent/completed(_:)``
    /// then resolves under this directory.
    public var outputDirectory: URL?

    /// Opt-in throttle for intermediate denoise previews.
    ///
    /// `nil` (the default) disables previews entirely — backends emit only
    /// ``ImageGenerationEvent/progress(step:total:)`` ticks and the terminal
    /// ``ImageGenerationEvent/completed(_:)``, exactly as before this knob
    /// existed. When set to `N`, backends that support previews emit an
    /// ``ImageGenerationEvent/preview(step:total:image:)`` every `N` steps so
    /// hosts can render a progressively-refining thumbnail mid-generation.
    ///
    /// Previews carry encoded image bytes in-memory rather than a file URL —
    /// see ``ImageGenerationEvent/preview(step:total:image:)`` for the
    /// per-tick-cost rationale. Larger strides trade preview smoothness for
    /// fewer encode passes; backends without preview support silently ignore
    /// this field, matching the ``ImageGenerationConfig`` convention.
    public var previewStride: Int?

    public init(
        steps: Int? = nil,
        width: Int = 1024,
        height: Int = 1024,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil,
        aspectRatio: String? = nil,
        outputDirectory: URL? = nil,
        previewStride: Int? = nil
    ) {
        self.steps = steps
        self.width = width
        self.height = height
        self.seed = seed
        self.guidanceScale = guidanceScale
        self.aspectRatio = aspectRatio
        self.outputDirectory = outputDirectory
        self.previewStride = previewStride
    }

    /// Convenience initializer that accepts a `CGSize`. Rounds to the
    /// nearest integer pixels — backends operate on whole-pixel resolutions,
    /// never fractions.
    public init(
        steps: Int? = nil,
        resolution: CGSize,
        seed: UInt64? = nil,
        guidanceScale: Float? = nil,
        outputDirectory: URL? = nil,
        previewStride: Int? = nil
    ) {
        self.init(
            steps: steps,
            width: Int(resolution.width.rounded()),
            height: Int(resolution.height.rounded()),
            seed: seed,
            guidanceScale: guidanceScale,
            outputDirectory: outputDirectory,
            previewStride: previewStride
        )
    }

    // MARK: - Codable

    // Custom Codable so `outputDirectory` rides as `encodeIfPresent` and an
    // older payload that omits it decodes to `nil` rather than failing.
    private enum CodingKeys: String, CodingKey {
        case steps, width, height, seed, guidanceScale, aspectRatio, outputDirectory, previewStride
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An old persisted/wire payload still carries an explicit `steps`
        // integer — decode it as present so pre-optional payloads round-trip.
        // A new payload omits the key entirely when `steps` is `nil`.
        self.steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        self.guidanceScale = try c.decodeIfPresent(Float.self, forKey: .guidanceScale)
        self.aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)
        self.outputDirectory = try c.decodeIfPresent(URL.self, forKey: .outputDirectory)
        self.previewStride = try c.decodeIfPresent(Int.self, forKey: .previewStride)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(steps, forKey: .steps)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(guidanceScale, forKey: .guidanceScale)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
        try c.encodeIfPresent(previewStride, forKey: .previewStride)
    }
}
