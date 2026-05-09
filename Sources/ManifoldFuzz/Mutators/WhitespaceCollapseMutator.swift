import Foundation

public struct WhitespaceCollapseMutator: Mutator {
    public let id = "whitespace-collapse"

    public init() {}

    public func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry {
        guard let userIdx = entry.turns.firstIndex(where: { $0.role == "user" }) else {
            return entry
        }
        let original = entry.turns[userIdx].text
        let useNewlines = Bool.random(using: &rng)

        let mutated: String
        if useNewlines {
            mutated = original.replacingOccurrences(of: " ", with: "\n")
        } else {
            let collapsed = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            mutated = collapsed
        }

        var turns = entry.turns
        turns[userIdx] = .init(role: turns[userIdx].role, text: mutated)
        return CorpusEntry(id: entry.id, category: entry.category, system: entry.system, turns: turns)
    }
}
