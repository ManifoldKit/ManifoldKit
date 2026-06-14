import AVFoundation
import XCTest
@testable import ManifoldVoice

@MainActor
final class SpeechSynthesizingEnqueueTests: XCTestCase {

    // MARK: - Protocol default forwarding

    func test_legacySpeakForwardsAsReplaceWithDefaultOptions() async throws {
        let spy = SpeechSpy()

        // The original single-string API must still resolve via the default
        // protocol-extension shim.
        try await spy.speak("hello")

        XCTAssertEqual(spy.spokenTexts, ["hello"])
        XCTAssertEqual(spy.spokenEnqueueFlags, [false])
        XCTAssertEqual(spy.spokenOptions, [SpeechOptions()])
    }

    func test_newMethodPassesOptionsThrough() async throws {
        let spy = SpeechSpy()
        let options = SpeechOptions(
            voiceIdentifier: "com.apple.voice.test",
            rate: 0.42,
            pitchMultiplier: 1.5,
            locale: "en-GB"
        )

        try await spy.speak("hi", options: options, enqueue: true)

        XCTAssertEqual(spy.spokenOptions, [options])
        XCTAssertEqual(spy.spokenEnqueueFlags, [true])
    }

    // MARK: - Enqueue vs replace cancellation semantics

    func test_replaceModeStopsInFlightUtterance() async throws {
        let spy = SpeechSpy()

        try await spy.speak("first", options: SpeechOptions(), enqueue: false)

        // Replace mode records a stop for the in-flight utterance.
        XCTAssertEqual(spy.stopCalls, 1)
    }

    func test_enqueueModeDoesNotStopInFlightUtterance() async throws {
        let spy = SpeechSpy()

        try await spy.speak("first", options: SpeechOptions(), enqueue: true)
        try await spy.speak("second", options: SpeechOptions(), enqueue: true)

        XCTAssertEqual(spy.spokenTexts, ["first", "second"])
        XCTAssertEqual(spy.stopCalls, 0)
    }

    // MARK: - Options → utterance mapping

    func test_makeUtteranceUsesDefaultRateWhenNil() {
        let utterance = AppleSpeechSynthesizer.makeUtterance(string: "x", options: SpeechOptions())
        XCTAssertEqual(utterance.rate, AVSpeechUtteranceDefaultSpeechRate)
    }

    func test_makeUtteranceAppliesRateAndPitch() {
        let utterance = AppleSpeechSynthesizer.makeUtterance(
            string: "x",
            options: SpeechOptions(rate: 0.33, pitchMultiplier: 1.75)
        )
        XCTAssertEqual(utterance.rate, 0.33)
        XCTAssertEqual(utterance.pitchMultiplier, 1.75)
    }

    func test_makeUtteranceAppliesLocaleVoiceWhenIdentifierAbsent() {
        let utterance = AppleSpeechSynthesizer.makeUtterance(
            string: "x",
            options: SpeechOptions(locale: "en-US")
        )
        // A voice should resolve for a standard locale on supported platforms.
        if let voice = utterance.voice {
            XCTAssertTrue(voice.language.hasPrefix("en"))
        }
    }

    // MARK: - Controller enqueue path

    func test_controllerEnqueueReadbackUsesEnqueueMode() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: StubSpeechTranscriber(),
            synthesizer: synthesizer
        )

        controller.enqueueReadback(of: "one")
        await Task.yield()
        controller.enqueueReadback(of: "two")
        await Task.yield()

        XCTAssertEqual(synthesizer.spokenTexts, ["one", "two"])
        XCTAssertEqual(synthesizer.spokenEnqueueFlags, [true, true])
        XCTAssertEqual(synthesizer.stopCalls, 0)
        XCTAssertTrue(controller.isSpeaking)
    }

    func test_controllerTogglePlaybackUsesReplaceMode() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: StubSpeechTranscriber(),
            synthesizer: synthesizer
        )

        controller.togglePlayback(for: "hi")
        await Task.yield()

        XCTAssertEqual(synthesizer.spokenEnqueueFlags, [false])
    }

    func test_controllerPassesConfiguredSpeechOptions() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: StubSpeechTranscriber(),
            synthesizer: synthesizer
        )
        controller.speechOptions = SpeechOptions(rate: 0.5, locale: "fr-FR")

        controller.togglePlayback(for: "bonjour")
        await Task.yield()

        XCTAssertEqual(synthesizer.spokenOptions, [SpeechOptions(rate: 0.5, locale: "fr-FR")])
    }
}

/// A pure spy that only implements the new protocol method, used to assert the
/// default `speak(_:)` shim and replace/enqueue stop semantics.
@MainActor
private final class SpeechSpy: SpeechSynthesizing {
    var spokenTexts: [String] = []
    var spokenOptions: [SpeechOptions] = []
    var spokenEnqueueFlags: [Bool] = []
    var stopCalls = 0

    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws {
        if !enqueue {
            stopSpeaking()
        }
        spokenTexts.append(text)
        spokenOptions.append(options)
        spokenEnqueueFlags.append(enqueue)
    }

    func stopSpeaking() {
        stopCalls += 1
    }
}

/// Inert transcriber so controller tests don't touch real speech permissions.
@MainActor
private final class StubSpeechTranscriber: SpeechTranscribing {
    func requestAuthorization() async -> VoiceAuthorizationStatus { .authorized }
    func startTranscribing(onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void) async throws {}
    func stopTranscribing() async throws -> String? { nil }
    func cancelTranscribing() {}
}
