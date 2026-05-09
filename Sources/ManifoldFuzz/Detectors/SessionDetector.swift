import Foundation

/// Multi-turn detector: consumes one or more ``SessionCapture`` instances
/// and emits findings that describe cross-turn or cross-session anomalies.
/// The single-turn ``Detector`` protocol is unchanged — session detectors
/// are a parallel hierarchy so per-step records still flow through the
/// existing ``DetectorRegistry``/``FuzzRunner`` path.
///
/// Detectors receive `[SessionCapture]` so the cross-session leak check can
/// inspect multiple independent sessions in one pass. Detectors that only
/// care about a single capture iterate the slice themselves.
public protocol SessionDetector: Sendable {
    var id: String { get }
    var humanName: String { get }
    var inspiredBy: String { get }
    func inspect(_ captures: [SessionCapture]) -> [Finding]
}

public extension SessionDetector {
    /// Single-capture convenience wrapper for detectors that are agnostic to
    /// whether they're run in batched mode.
    func inspect(_ capture: SessionCapture) -> [Finding] {
        inspect([capture])
    }
}

/// Session-aware counterpart to ``DetectorRegistry``. Held separately so the
/// single-turn registry stays source-compatible with callers that iterate
/// `DetectorRegistry.all`.
public enum SessionDetectorRegistry {
    public static let all: [any SessionDetector] = [
        TurnBoundaryKVStateDetector(),
        CancellationRaceDetector(),
        SessionContextLeakDetector(),
    ]

    public static func resolve(_ filter: Set<String>?) -> [any SessionDetector] {
        guard let filter else { return all }
        return all.filter { filter.contains($0.id) }
    }
}
