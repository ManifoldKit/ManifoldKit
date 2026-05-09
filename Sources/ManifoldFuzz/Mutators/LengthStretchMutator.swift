import Foundation

public struct LengthStretchMutator: Mutator {
    public let id = "length-stretch"

    public init() {}

    public func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry {
        guard let userIdx = entry.turns.firstIndex(where: { $0.role == "user" }) else {
            return entry
        }
        let factor = [2, 5, 10].randomElement(using: &rng)!
        let original = entry.turns[userIdx].text
        let stretched = Array(repeating: original, count: factor).joined(separator: " ")

        var turns = entry.turns
        turns[userIdx] = .init(role: turns[userIdx].role, text: stretched)
        return CorpusEntry(id: entry.id, category: entry.category, system: entry.system, turns: turns)
    }
}
