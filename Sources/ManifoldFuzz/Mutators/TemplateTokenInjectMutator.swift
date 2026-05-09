import Foundation

public struct TemplateTokenInjectMutator: Mutator {
    public let id = "template-token-inject"

    static let tokens: [String] = [
        "<|im_start|>",
        "<|im_end|>",
        "[INST]",
        "[/INST]",
        "<|eot_id|>",
        "<|user|>",
        "<start_of_turn>",
        "<end_of_turn>",
    ]

    public init() {}

    public func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry {
        guard let userIdx = entry.turns.firstIndex(where: { $0.role == "user" }) else {
            return entry
        }
        let token = Self.tokens.randomElement(using: &rng)!
        let original = entry.turns[userIdx].text
        let chars = Array(original)
        let insertAt = chars.isEmpty ? 0 : chars.count / 2
        var mutated = String(chars[0..<insertAt])
        mutated += token
        mutated += String(chars[insertAt..<chars.count])

        var turns = entry.turns
        turns[userIdx] = .init(role: turns[userIdx].role, text: mutated)
        return CorpusEntry(id: entry.id, category: entry.category, system: entry.system, turns: turns)
    }
}
