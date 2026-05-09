import Foundation

public struct UnicodeInjectMutator: Mutator {
    public let id = "unicode-inject"

    // RTL override, ZWJ, BOM, and a lone-high-surrogate-shaped scalar (U+D7FF is the
    // last legal scalar before the surrogate range — used as a tokenizer-edge probe).
    static let payloads: [Character] = [
        "\u{202E}",
        "\u{200D}",
        "\u{FEFF}",
        "\u{D7FF}",
    ]

    public init() {}

    public func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry {
        guard let userIdx = entry.turns.firstIndex(where: { $0.role == "user" }) else {
            return entry
        }
        var chars = Array(entry.turns[userIdx].text)
        let injectionCount = max(1, chars.count / 8)
        for _ in 0..<injectionCount {
            let payload = Self.payloads.randomElement(using: &rng)!
            let insertAt = chars.isEmpty ? 0 : Int.random(in: 0...chars.count, using: &rng)
            chars.insert(payload, at: insertAt)
        }
        var turns = entry.turns
        turns[userIdx] = .init(role: turns[userIdx].role, text: String(chars))
        return CorpusEntry(id: entry.id, category: entry.category, system: entry.system, turns: turns)
    }
}
