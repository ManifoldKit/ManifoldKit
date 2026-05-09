import Foundation

public protocol Detector: Sendable {
    var id: String { get }
    var humanName: String { get }
    var inspiredBy: String { get }
    func inspect(_ record: RunRecord) -> [Finding]
}

public enum DetectorRegistry {
    public static let all: [any Detector] = [
        ThinkingClassificationDetector(),
        LoopingDetector(),
        EmptyOutputAfterWorkDetector(),
        TemplateTokenLeakDetector(),
        MemoryGrowthDetector(),
        KVCollisionDetector(),
        EmptyVisibleAfterThinkDetector(),
        RaceStallDetector(),
        ContextExhaustionSilentDetector(),
        TimeoutDetector(),
        ToolCallValidityDetector(),
    ]

    public static func resolve(_ filter: Set<String>?) -> [any Detector] {
        guard let filter else { return all }
        return all.filter { filter.contains($0.id) }
    }
}
