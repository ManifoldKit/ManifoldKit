#if Voice
import XCTest
@testable import BaseChatVoice

@MainActor
final class WakeWordDetectorTests: XCTestCase {
    func test_detectorMatchesNormalizedWakeWordOncePerSession() {
        let detector = AppleWakeWordDetector(wakeWords: ["Hey, Base Chat"])

        XCTAssertNil(detector.ingest(.init(text: "hello there", isFinal: false)))

        let first = detector.ingest(.init(text: "hey base chat, start a new note", isFinal: false))
        XCTAssertEqual(
            first,
            WakeWordDetection(
                phrase: "Hey, Base Chat",
                transcript: "hey base chat, start a new note"
            )
        )

        XCTAssertNil(detector.ingest(.init(text: "hey base chat, keep listening", isFinal: false)))

        detector.reset()

        let second = detector.ingest(.init(text: "HEY BASE CHAT do it again", isFinal: false))
        XCTAssertEqual(
            second,
            WakeWordDetection(
                phrase: "Hey, Base Chat",
                transcript: "HEY BASE CHAT do it again"
            )
        )
    }

    func test_detectorIgnoresBlankConfiguredWakeWords() {
        let detector = AppleWakeWordDetector(wakeWords: ["", "   "])

        XCTAssertNil(detector.ingest(.init(text: "hey base chat", isFinal: false)))
    }
}
#endif
