@preconcurrency import AVFoundation
import XCTest
@testable import ManifoldInference

/// Coverage for the quality-aware voice ranking and resolution added to
/// ``AppleTTSBackend``. The ranking is exercised through pure ``VoiceDescriptor``
/// values so the assertions are deterministic on any host — installed voices
/// vary by machine, but the *ordering rules* must not.
final class VoiceSelectionTests: XCTestCase {

    private func v(_ id: String, _ name: String, _ lang: String, _ q: VoiceDescriptor.Quality) -> VoiceDescriptor {
        VoiceDescriptor(id: id, name: name, language: lang, quality: q)
    }

    // MARK: - Quality dominates

    func test_ranking_prefersPremiumOverEnhancedOverStandard() {
        let premium = v("com.apple.voice.premium.en-US.Ava", "Ava", "en-US", .premium)
        let enhanced = v("com.apple.voice.enhanced.en-US.Evan", "Evan", "en-US", .enhanced)
        let standard = v("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)

        let ranked = AppleTTSBackend.ranked([standard, premium, enhanced])

        XCTAssertEqual(ranked.map(\.name), ["Ava", "Evan", "Samantha"])
    }

    // MARK: - Novelty trap

    func test_ranking_compactSamanthaBeatsNoveltyAtEqualQuality() {
        // Zarvox / Bells are legacy MacinTalk voices at the SAME standard tier
        // as compact Samantha — a naive max(by: quality) could surface them.
        let samantha = v("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)
        let zarvox = v("com.apple.speech.synthesis.voice.Zarvox", "Zarvox", "en-US", .standard)
        let bells = v("com.apple.speech.synthesis.voice.Bells", "Bells", "en-US", .standard)

        let ranked = AppleTTSBackend.ranked([zarvox, bells, samantha])

        XCTAssertEqual(ranked.first?.name, "Samantha", "Modern Siri voice must outrank novelty voices")
        XCTAssertEqual(Set(ranked.suffix(2).map(\.name)), ["Zarvox", "Bells"])
    }

    func test_ranking_compactBeatsSuperCompactAtEqualQuality() {
        let compact = v("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", .standard)
        let superCompact = v("com.apple.voice.super-compact.en-AU.Karen", "Karen", "en-AU", .standard)

        let ranked = AppleTTSBackend.ranked([superCompact, compact])

        XCTAssertEqual(ranked.first?.name, "Samantha")
    }

    func test_ranking_enhancedNoveltyStillLosesToPremiumSiri() {
        // Quality must dominate the family bonus: a premium Siri voice beats an
        // (implausible) enhanced novelty voice.
        let premiumSiri = v("com.apple.voice.premium.en-US.Ava", "Ava", "en-US", .premium)
        let enhancedNovelty = v("com.apple.speech.synthesis.voice.Zarvox", "Zarvox", "en-US", .enhanced)

        let ranked = AppleTTSBackend.ranked([enhancedNovelty, premiumSiri])

        XCTAssertEqual(ranked.first?.name, "Ava")
    }

    func test_ranking_tieBreaksAlphabeticallyAndStably() {
        let a = v("com.apple.voice.compact.en-US.Aaron", "Aaron", "en-US", .standard)
        let z = v("com.apple.voice.compact.en-US.Zoe", "Zoe", "en-US", .standard)

        XCTAssertEqual(AppleTTSBackend.ranked([z, a]).map(\.name), ["Aaron", "Zoe"])
        XCTAssertEqual(AppleTTSBackend.ranked([a, z]).map(\.name), ["Aaron", "Zoe"])
    }

    // MARK: - Language matching

    func test_languageMatches_exactAndPrimarySubtag() {
        XCTAssertTrue(AppleTTSBackend.languageMatches("en-US", "en-US"))
        XCTAssertTrue(AppleTTSBackend.languageMatches("en-US", "EN-us"))   // case-insensitive
        XCTAssertTrue(AppleTTSBackend.languageMatches("en-GB", "en"))      // primary subtag
        XCTAssertFalse(AppleTTSBackend.languageMatches("fr-FR", "en-US"))
        XCTAssertFalse(AppleTTSBackend.languageMatches("en-US", "es"))
    }

    // MARK: - Quality bridging

    func test_quality_bridgesAVQuality() {
        XCTAssertEqual(VoiceDescriptor.Quality(.premium), .premium)
        XCTAssertEqual(VoiceDescriptor.Quality(.enhanced), .enhanced)
        XCTAssertEqual(VoiceDescriptor.Quality(.default), .standard)
    }

    // MARK: - Host enumeration (smoke; host-dependent)

    func test_availableVoices_returnsRankedNonEmptyAndSorted() {
        let all = AppleTTSBackend.availableVoices()
        // Every test host ships at least one voice.
        XCTAssertFalse(all.isEmpty, "Expected installed system voices")
        // Output must be in non-increasing score order.
        let scores = all.map(AppleTTSBackend.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "availableVoices must be ranked best-first")
    }

    func test_availableVoices_languageFilterRestrictsToPrimarySubtag() {
        let english = AppleTTSBackend.availableVoices(language: "en")
        // Filter is honoured: nothing outside the en-* family leaks in.
        XCTAssertTrue(english.allSatisfy { $0.language.lowercased().hasPrefix("en") },
                      "Language filter must restrict to the requested primary subtag")
    }

    // MARK: - Resolution

    func test_resolveVoice_nilVoice_picksAnInstalledVoice() {
        // With no voice requested the backend now resolves a concrete voice
        // rather than leaving the utterance on the bare system default.
        let resolved = AppleTTSBackend.resolveVoice(config: SpeechGenerationConfig(text: "hi"))
        XCTAssertNotNil(resolved, "Expected a resolved default voice on a host with installed voices")
    }

    func test_resolveVoice_explicitIdentifierWins() throws {
        // Pick a real installed identifier and confirm it is honoured verbatim.
        let some = try XCTUnwrap(AppleTTSBackend.availableVoices().first)
        let resolved = AppleTTSBackend.resolveVoice(config: SpeechGenerationConfig(text: "hi", voice: some.id))
        XCTAssertEqual(resolved?.identifier, some.id)
    }
}
