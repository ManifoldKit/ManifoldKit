#if Fuzz
import XCTest
@testable import BaseChatFuzz

final class MutatorTests: XCTestCase {

    private func sampleEntry(text: String = "Hello world, please summarise this paragraph.") -> CorpusEntry {
        CorpusEntry(
            id: "test-1",
            category: "test",
            system: nil,
            turns: [.init(role: "user", text: text)]
        )
    }

    // MARK: - LengthStretch

    func test_lengthStretch_growsUserTurn() {
        var rng = SeededRNG(seed: 42)
        let entry = sampleEntry(text: "abc")
        let mutated = LengthStretchMutator().mutate(entry, rng: &rng)
        XCTAssertGreaterThan(mutated.turns[0].text.count, entry.turns[0].text.count)
        XCTAssertTrue(mutated.turns[0].text.contains("abc"))
        let factor = (mutated.turns[0].text.components(separatedBy: "abc").count - 1)
        XCTAssertTrue([2, 5, 10].contains(factor), "Expected duplication factor 2/5/10, got \(factor)")
    }

    // MARK: - UnicodeInject

    func test_unicodeInject_addsAtLeastOnePayloadCodepoint() {
        var rng = SeededRNG(seed: 7)
        let entry = sampleEntry()
        let mutated = UnicodeInjectMutator().mutate(entry, rng: &rng)
        let scalars = mutated.turns[0].text.unicodeScalars
        let payloadValues: Set<UInt32> = [0x202E, 0x200D, 0xFEFF, 0xD7FF]
        let hit = scalars.contains { payloadValues.contains($0.value) }
        XCTAssertTrue(hit, "Expected at least one injected payload code point")
    }

    // MARK: - TemplateTokenInject

    func test_templateTokenInject_leavesRecognisableToken() {
        var rng = SeededRNG(seed: 99)
        let entry = sampleEntry()
        let mutated = TemplateTokenInjectMutator().mutate(entry, rng: &rng)
        let injected = TemplateTokenInjectMutator.tokens.first(where: { mutated.turns[0].text.contains($0) })
        XCTAssertNotNil(injected, "Mutated user turn should contain one of the documented template tokens")
    }

    // MARK: - MultiTurn

    func test_multiTurn_produces2to5Turns() {
        var rng = SeededRNG(seed: 11)
        let entry = sampleEntry()
        let mutated = MultiTurnMutator().mutate(entry, rng: &rng)
        XCTAssertTrue((2...5).contains(mutated.turns.count), "Got \(mutated.turns.count) turns")
        XCTAssertEqual(mutated.turns[0].role, "user")
        if mutated.turns.count > 1 {
            XCTAssertEqual(mutated.turns[1].role, "assistant")
        }
    }

    // MARK: - SystemPrompt

    func test_systemPrompt_picksDocumentedOption() {
        var rng = SeededRNG(seed: 555)
        let entry = sampleEntry()
        let mutated = SystemPromptMutator().mutate(entry, rng: &rng)
        let allowed: [String?] = SystemPromptMutator.options
        XCTAssertTrue(allowed.contains(where: { $0 == mutated.system }))
    }

    // MARK: - WhitespaceCollapse

    func test_whitespaceCollapse_changesWhitespaceStructure() {
        let entry = sampleEntry(text: "one  two\t three\n four")
        var rngA = SeededRNG(seed: 1)
        let mutatedA = WhitespaceCollapseMutator().mutate(entry, rng: &rngA)
        XCTAssertNotEqual(mutatedA.turns[0].text, entry.turns[0].text)

        var rngB = SeededRNG(seed: 2)
        let mutatedB = WhitespaceCollapseMutator().mutate(entry, rng: &rngB)
        XCTAssertNotEqual(mutatedB.turns[0].text, entry.turns[0].text)
    }

    // MARK: - Chain determinism

    func test_mutatorChain_isDeterministicForFixedSeed() {
        let entry = sampleEntry(text: "deterministic input here")

        var rng1 = SeededRNG(seed: 12345)
        let (out1, ids1) = MutatorChain.allRandom(entry, rng: &rng1)

        var rng2 = SeededRNG(seed: 12345)
        let (out2, ids2) = MutatorChain.allRandom(entry, rng: &rng2)

        XCTAssertEqual(ids1, ids2)
        XCTAssertEqual(out1.turns.map(\.text), out2.turns.map(\.text))
        XCTAssertEqual(out1.turns.map(\.role), out2.turns.map(\.role))
        XCTAssertEqual(out1.system, out2.system)
    }

    func test_mutatorChain_appliesBetween0And3Mutators() {
        for seed in UInt64(1)...50 {
            var rng = SeededRNG(seed: seed)
            let (_, ids) = MutatorChain.allRandom(sampleEntry(), rng: &rng)
            XCTAssertTrue((0...3).contains(ids.count), "seed \(seed) produced \(ids.count) mutators")
        }
    }
}
#endif
