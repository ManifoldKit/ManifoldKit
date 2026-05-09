import Testing
import Foundation
import ManifoldInference

@Suite("RepetitionDetector")
struct RepetitionDetectorTests {

    // MARK: - 3x detection tests

    @Test("Triple repeat of 8+ char unit is detected")
    func test_tripleRepeat_detected() {
        // 20-char unit repeated 3 times = 60 chars total
        let unit = String(repeating: "a", count: 20)
        let text = String(repeating: unit, count: 3)
        #expect(RepetitionDetector.looksLikeLooping(text))
    }

    @Test("Triple repeat at exact 8-char boundary is detected")
    func test_8charUnit_tripleRepeat_detected() {
        let unit = "abcdefgh" // exactly 8 chars
        // Need total >= 48 chars: 8 * 3 = 24, pad front to reach 48
        let padding = String(repeating: "x", count: 24)
        let text = padding + String(repeating: unit, count: 3)
        #expect(RepetitionDetector.looksLikeLooping(text))
    }

    @Test("7-char unit triple repeat is not detected (below min unit)")
    func test_7charUnit_notDetected() {
        let unit = "abcdefg" // 7 chars
        let padding = String(repeating: "x", count: 27)
        let text = padding + String(repeating: unit, count: 3)
        #expect(!RepetitionDetector.looksLikeLooping(text))
    }

    // MARK: - 2x detection tests

    @Test("Double repeat of 50+ char unit is detected")
    func test_doubleRepeat_50plusChars_detected() {
        // Use a unique 55-char unit so no substring triggers 3x detection
        let unit = "The world was dark and full of ancient forgotten mystery" // 56 chars
        #expect(unit.count == 56)
        let text = unit + unit // 112 chars, 2x repeat of 56-char unit
        #expect(RepetitionDetector.looksLikeLooping(text))
    }

    @Test("Double repeat of < 50 chars is not detected as 2x loop")
    func test_doubleRepeat_under50_notDetected() {
        // 45-char unique unit repeated twice = 90 chars
        // Below 2x threshold (requires 50+) and only 2 copies so no 3x match
        let unit = "A moderately long but still unique test phrase" // 46 chars
        #expect(unit.count == 46)
        let text = unit + unit // 92 chars
        #expect(!RepetitionDetector.looksLikeLooping(text))
    }

    // MARK: - Short input safety

    @Test("Input under 48 chars never triggers 3x detection")
    func test_shortInput_under48_safe() {
        let shortTexts = [
            "",
            "Hello",
            "abcabc",
            String(repeating: "a", count: 47),
        ]
        for text in shortTexts {
            #expect(!RepetitionDetector.looksLikeLooping(text), "False positive on: \(text)")
        }
    }

    // MARK: - False positive tests

    @Test("Normal prose does not trigger loop detection")
    func test_normalProse_noFalsePositive() {
        let prose = """
        The knight rode through the valley, his armor gleaming in the afternoon sun. \
        Beside him, the squire carried the banner of their lord. They had traveled \
        for three days without rest, driven by the urgency of the king's summons. \
        The road wound through ancient forests and across stone bridges that had stood \
        for centuries. Each mile brought them closer to the capital and the uncertain \
        fate that awaited them there.
        """
        #expect(!RepetitionDetector.looksLikeLooping(prose))
    }

    @Test("Dialogue with repeated tags does not false-positive")
    func test_dialogueTags_noFalsePositive() {
        let dialogue = """
        "I don't know," he said. "Maybe we should wait."
        "Wait for what?" she said. "The storm won't pass."
        "You're right," he said. "Let's move then."
        "Finally," she said. "I was getting cold."
        "I know," he said. "Me too."
        "Then hurry," she said. "Before it gets worse."
        """
        #expect(!RepetitionDetector.looksLikeLooping(dialogue))
    }

    @Test("Bulleted list with repeated prefixes does not false-positive")
    func test_bulletedList_noFalsePositive() {
        let list = """
        - Item: The sword of light, found in the western cave.
        - Item: The shield of ages, recovered from the ruins.
        - Item: The helm of vision, traded from the merchant.
        - Item: The boots of swiftness, looted from the bandit.
        - Item: The cloak of shadows, gifted by the witch.
        - Item: The ring of power, inherited from the king.
        """
        #expect(!RepetitionDetector.looksLikeLooping(list))
    }

    // MARK: - Repetition rate metric

    @Test("Repetition rate of empty string is 0.0")
    func test_repetitionRate_zeroLength() {
        #expect(RepetitionDetector.repetitionRate(of: "") == 0.0)
    }

    @Test("Repetition rate of unique text is 0.0")
    func test_repetitionRate_uniqueText() {
        // Text shorter than the minimum unit range won't match
        let text = "Each word here is completely unique and different from every other word in this text."
        let rate = RepetitionDetector.repetitionRate(of: text, unitRange: 40...50)
        #expect(rate == 0.0)
    }

    @Test("Repetition rate of fully repeated text approaches 1.0")
    func test_repetitionRate_fullyRepeated() {
        let unit = String(repeating: "The model repeated this exact phrase. ", count: 1)
        let text = String(repeating: unit, count: 10)
        let rate = RepetitionDetector.repetitionRate(of: text, unitRange: 20...30)
        #expect(rate > 0.5, "Expected high repetition rate for repeated text, got \(rate)")
    }
}
