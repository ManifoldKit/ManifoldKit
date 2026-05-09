import Foundation

public struct MultiTurnMutator: Mutator {
    public let id = "multi-turn"

    static let assistantReplies: [String] = [
        "Got it.",
        "Continue.",
        "Tell me more.",
        "Understood — go on.",
    ]

    public init() {}

    public func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry {
        guard let firstUser = entry.turns.first(where: { $0.role == "user" }) else {
            return entry
        }
        let totalTurns = Int.random(in: 2...5, using: &rng)
        var turns: [CorpusEntry.Turn] = []
        for i in 0..<totalTurns {
            if i % 2 == 0 {
                turns.append(.init(role: "user", text: firstUser.text))
            } else {
                let reply = Self.assistantReplies.randomElement(using: &rng)!
                turns.append(.init(role: "assistant", text: reply))
            }
        }
        return CorpusEntry(id: entry.id, category: entry.category, system: entry.system, turns: turns)
    }
}
