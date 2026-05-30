import Foundation

/// Configuration for a cloud video-generation request.
public struct VideoGenerationConfig: Sendable, Hashable {

    public enum AspectRatio: String, Sendable, CaseIterable, Hashable {
        case landscape = "16:9"
        case portrait = "9:16"
        case square = "1:1"
        case wide = "4:3"
        case tall = "3:4"

        public var displayName: String {
            switch self {
            case .landscape: "16:9"
            case .portrait: "9:16"
            case .square: "1:1"
            case .wide: "4:3"
            case .tall: "3:4"
            }
        }
    }

    public enum Resolution: String, Sendable, CaseIterable, Hashable {
        case hd = "720p"
        case sd = "480p"
    }

    /// Duration in seconds (1–15).
    public var duration: Int
    public var aspectRatio: AspectRatio
    public var resolution: Resolution
    /// Local file URL of a source image for image-to-video mode.
    public var sourceImageURL: URL?

    public init(
        duration: Int = 5,
        aspectRatio: AspectRatio = .landscape,
        resolution: Resolution = .hd,
        sourceImageURL: URL? = nil
    ) {
        self.duration = min(max(duration, 1), 15)
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.sourceImageURL = sourceImageURL
    }
}
