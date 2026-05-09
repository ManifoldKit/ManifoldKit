import Foundation

// SeededRNG is `public` so mutators can take it `inout` directly. Using
// `inout some RandomNumberGenerator` in a protocol requirement isn't expressible,
// and `inout any RandomNumberGenerator` would defeat determinism guarantees.
public protocol Mutator: Sendable {
    var id: String { get }
    func mutate(_ entry: CorpusEntry, rng: inout SeededRNG) -> CorpusEntry
}

public enum MutatorRegistry {
    public static let all: [any Mutator] = [
        LengthStretchMutator(),
        UnicodeInjectMutator(),
        TemplateTokenInjectMutator(),
        MultiTurnMutator(),
        SystemPromptMutator(),
        WhitespaceCollapseMutator(),
    ]
}

public enum MutatorChain {
    /// Picks 0–3 mutators uniformly at random and applies them in order.
    /// Returns the mutated entry along with the ids of the applied mutators.
    public static func allRandom(
        _ entry: CorpusEntry,
        rng: inout SeededRNG,
        pool: [any Mutator] = MutatorRegistry.all
    ) -> (CorpusEntry, [String]) {
        let count = Int.random(in: 0...3, using: &rng)
        guard count > 0, !pool.isEmpty else { return (entry, []) }

        var current = entry
        var ids: [String] = []
        for _ in 0..<count {
            let mutator = pool.randomElement(using: &rng)!
            current = mutator.mutate(current, rng: &rng)
            ids.append(mutator.id)
        }
        return (current, ids)
    }
}
