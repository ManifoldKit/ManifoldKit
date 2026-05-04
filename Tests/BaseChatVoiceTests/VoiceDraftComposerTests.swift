#if Voice
import XCTest
@testable import BaseChatVoice

final class VoiceDraftComposerTests: XCTestCase {
    func test_appendStrategyAddsTranscriptOnNewLine() {
        XCTAssertEqual(
            VoiceDraftComposer.merge(
                transcript: "Dictated follow-up",
                into: "Existing draft",
                strategy: .append
            ),
            "Existing draft\nDictated follow-up"
        )
    }

    func test_replaceStrategyOverwritesExistingDraft() {
        XCTAssertEqual(
            VoiceDraftComposer.merge(
                transcript: "Fresh transcript",
                into: "Existing draft",
                strategy: .replace
            ),
            "Fresh transcript"
        )
    }
}
#endif
