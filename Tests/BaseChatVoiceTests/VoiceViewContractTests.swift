#if Voice
import XCTest
import ViewInspector
@testable import BaseChatVoice

@MainActor
final class VoiceViewContractTests: XCTestCase {
    func test_voiceInputButtonUsesRecordingAccessibilityContract() throws {
        let idle = VoiceInputButton(isRecording: false, action: {})
        let active = VoiceInputButton(isRecording: true, action: {})

        let idleLabel = try idle.inspect()
            .find(ViewType.Button.self)
            .accessibilityLabel()
            .string()
        let activeLabel = try active.inspect()
            .find(ViewType.Button.self)
            .accessibilityLabel()
            .string()

        XCTAssertEqual(idleLabel, "Start voice capture")
        XCTAssertEqual(activeLabel, "Stop voice capture")
    }

    func test_liveTranscriptionViewRendersTitleAndTranscript() throws {
        let view = LiveTranscriptionView(text: "Hello from speech", title: "Voice draft")

        XCTAssertEqual(try view.inspect().find(text: "Voice draft").string(), "Voice draft")
        XCTAssertEqual(try view.inspect().find(text: "Hello from speech").string(), "Hello from speech")
    }

    func test_wakeWordToastUsesAccessibilityContract() throws {
        let view = WakeWordToast(phrase: "hey base chat")

        let label = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "wake-word-toast")
            .accessibilityLabel()
            .string()

        XCTAssertEqual(label, "Wake word detected: hey base chat")
        XCTAssertEqual(label, WakeWordToast.accessibilityLabel(for: "hey base chat"))
    }
}
#endif
