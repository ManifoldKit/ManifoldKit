import XCTest
@testable import ManifoldVoice

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
