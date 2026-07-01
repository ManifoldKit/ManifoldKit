import Foundation

/// Detects vision-language model directories by their config marker files.
///
/// Driving a vision-language model through a text-only inference path can
/// fail catastrophically rather than cleanly — e.g. a hard SIGSEGV with an
/// empty log — so text-only scenario-CLI harnesses pre-flight-check the model
/// directory before attempting to load it and refuse with a clear message
/// instead. Both companion scenario-CLI harnesses (manifold-mlx,
/// manifold-llama) had independently hand-rolled this exact check; this is
/// the single canonical implementation.
public enum VLModelDetector {

    /// Config file names present in HuggingFace-style vision-language model
    /// directories but absent from text-only model directories. Extend this
    /// list as new VL architectures ship with different marker files.
    public static let markerFileNames: [String] = [
        "preprocessor_config.json",
        "processor_config.json",
        "video_preprocessor_config.json",
    ]

    /// Returns the first marker file name found directly inside `directory`,
    /// or `nil` when none are present — including when `directory` doesn't
    /// exist or isn't a directory.
    public static func matchedMarkerFile(at directory: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        for marker in markerFileNames {
            let markerPath = directory.appendingPathComponent(marker).path
            if FileManager.default.fileExists(atPath: markerPath) {
                return marker
            }
        }
        return nil
    }

    /// Returns `true` when `directory` looks like a vision-language model
    /// directory (contains any of ``markerFileNames``).
    public static func isVisionLanguageModel(at directory: URL) -> Bool {
        matchedMarkerFile(at: directory) != nil
    }
}
