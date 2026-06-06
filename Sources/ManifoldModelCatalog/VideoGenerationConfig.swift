import Foundation

/// Configuration for a cloud video-generation request.
///
/// Fields represent the lowest common denominator across cloud video services.
/// Backends are responsible for validating their own limits and mapping these
/// values to their API's parameter names. Fields that a backend does not
/// support can be safely ignored.
///
/// ## Aspect ratio
/// Pass any string your backend accepts. ``AspectRatio`` provides named
/// constants for common values, but the field is a plain `String` so backends
/// that use non-standard notation (e.g. `"LANDSCAPE"`, `"widescreen"`) are not
/// constrained to this enum.
///
/// ## Resolution
/// Express as explicit pixel dimensions via ``width`` and ``height``. `nil`
/// means "use the backend's default." Backends that accept resolution as a
/// named tier (e.g. `"720p"`) should derive that tier from these values or
/// use a fixed default.
///
/// ## Duration
/// Stored as-is; no clamping is applied. Each backend enforces its own
/// minimum and maximum.
public struct VideoGenerationConfig: Sendable, Hashable, Codable {

    /// Named constants for common aspect ratios.
    ///
    /// The field accepts any `String`, so backends are not limited to these
    /// values. Use these constants for portability across backends that share
    /// the same notation.
    public enum AspectRatio {
        public static let landscape = "16:9"
        public static let portrait  = "9:16"
        public static let square    = "1:1"
        public static let wide      = "4:3"
        public static let tall      = "3:4"
    }

    /// Duration in seconds. Backends enforce their own min/max.
    public let duration: Int

    /// Aspect ratio string (e.g. `"16:9"`). Defaults to
    /// ``AspectRatio/landscape``. Pass any string your backend accepts.
    public let aspectRatio: String

    /// Output width in pixels. `nil` → backend default.
    public let width: Int?

    /// Output height in pixels. `nil` → backend default.
    public let height: Int?

    /// Local file URL of a source image for image-to-video mode.
    public let sourceImageURL: URL?

    public init(
        duration: Int = 5,
        aspectRatio: String = AspectRatio.landscape,
        width: Int? = nil,
        height: Int? = nil,
        sourceImageURL: URL? = nil
    ) {
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.sourceImageURL = sourceImageURL
    }
}
