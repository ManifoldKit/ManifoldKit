import AVFoundation
import XCTest
@testable import ManifoldVoice

/// Covers the spoken-range progress surface (#1831): the `NSRange` → Swift range
/// conversion, the `SpeechProgress` value semantics, and that
/// `AppleSpeechSynthesizer` exposes the optional `SpeechProgressReporting` hook.
/// The live `willSpeakRangeOfSpeechString` delegate is not driven here — that
/// requires real audio playback — so the conversion is tested through the
/// extracted `makeProgress` seam, mirroring `makeUtterance`.
@MainActor
final class SpeechProgressTests: XCTestCase {

    func test_makeProgress_mapsUTF16RangeToSpokenSubstring() {
        let id = UUID()
        let progress = AppleSpeechSynthesizer.makeProgress(
            utteranceID: id,
            nsRange: NSRange(location: 6, length: 5),
            text: "Hello world"
        )
        XCTAssertEqual(progress?.utteranceID, id)
        XCTAssertEqual(progress?.text, "Hello world")
        XCTAssertEqual(progress?.spokenText, "world")
    }

    func test_makeProgress_handlesNonASCIIViaUTF16Offsets() {
        // "café" is 4 Characters but the word after the space starts at UTF-16
        // offset 5. The conversion must land on the Swift substring "déjà".
        let text = "café déjà"
        let progress = AppleSpeechSynthesizer.makeProgress(
            utteranceID: UUID(),
            nsRange: NSRange(location: 5, length: 4),
            text: text
        )
        XCTAssertEqual(progress?.spokenText, "déjà")
    }

    func test_makeProgress_returnsNilForOutOfBoundsRange() {
        let progress = AppleSpeechSynthesizer.makeProgress(
            utteranceID: UUID(),
            nsRange: NSRange(location: 50, length: 5),
            text: "short"
        )
        XCTAssertNil(progress)
    }

    func test_speechProgress_spokenTextDerivesFromCarriedTextAndRange() {
        let text = "read along"
        let range = text.range(of: "along")!
        let progress = SpeechProgress(utteranceID: UUID(), text: text, spokenRange: range)
        XCTAssertEqual(progress.spokenText, "along")
    }

    func test_appleSynthesizer_exposesProgressReportingHook() {
        let synth = AppleSpeechSynthesizer()
        // The capability is opt-in: nil until a host installs a handler.
        XCTAssertNil(synth.onSpeechProgress)
        synth.onSpeechProgress = { _ in }
        XCTAssertNotNil(synth.onSpeechProgress)
        // And it is reachable through the optional-capability protocol.
        XCTAssertNotNil(synth as? SpeechProgressReporting)
    }
}
