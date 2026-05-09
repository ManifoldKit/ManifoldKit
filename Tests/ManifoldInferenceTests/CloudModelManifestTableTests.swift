import XCTest
@testable import ManifoldInference

final class CloudModelManifestTableTests: XCTestCase {

    // MARK: - OpenAI lookup

    func test_openAI_gpt4oMini_matchesSpecificEntry() {
        let manifest = CloudModelManifestTable.openAI(modelName: "gpt-4o-mini")
        XCTAssertEqual(manifest.modelIdentifier, "gpt-4o-mini")
        XCTAssertEqual(manifest.contextWindow, 128_000)
        XCTAssertTrue(manifest.supportsSeed,
                      "gpt-4o-mini accepts the OpenAI seed parameter")
        XCTAssertFalse(manifest.supportsThinking)
    }

    func test_openAI_gpt4oFollowsLongerPrefixWins() {
        // `gpt-4o-2024-08-06` should match the `gpt-4o` entry, not fall through to `gpt-4`.
        let manifest = CloudModelManifestTable.openAI(modelName: "gpt-4o-2024-08-06")
        XCTAssertEqual(manifest.modelIdentifier, "gpt-4o")
        XCTAssertEqual(manifest.contextWindow, 128_000)
    }

    func test_openAI_o1Family_isReasoningWithoutSeed() {
        let manifest = CloudModelManifestTable.openAI(modelName: "o1-2024-12-17")
        XCTAssertTrue(manifest.supportsThinking,
                      "o1 family is a reasoning model")
        XCTAssertFalse(manifest.supportsSeed,
                       "o1 family rejects the seed parameter — must be omitted from request bodies")
        XCTAssertFalse(manifest.supportedSamplingParameters.contains(.presencePenalty),
                       "o1 reasoning models reject presence/frequency penalties on the wire")
    }

    func test_openAI_o3_isReasoningWithoutSeed() {
        let manifest = CloudModelManifestTable.openAI(modelName: "o3")
        XCTAssertTrue(manifest.supportsThinking)
        XCTAssertFalse(manifest.supportsSeed)
    }

    func test_openAI_unknownModel_returnsUnknownManifest() {
        let manifest = CloudModelManifestTable.openAI(modelName: "imaginary-model-x")
        XCTAssertEqual(manifest.modelIdentifier, "imaginary-model-x")
        XCTAssertEqual(manifest.contextWindow, 8192)
        XCTAssertFalse(manifest.supportsSeed)
        XCTAssertEqual(manifest.producerKind, .cloud)
    }

    // MARK: - Claude lookup

    func test_claude_sonnet4Family_supportsExtendedThinking() {
        let manifest = CloudModelManifestTable.claude(modelName: "claude-sonnet-4-20250514")
        XCTAssertEqual(manifest.modelIdentifier, "claude-sonnet-4")
        XCTAssertTrue(manifest.supportsThinking,
                      "Claude 4-class models support extended thinking by default")
        XCTAssertFalse(manifest.supportsSeed,
                       "Anthropic Messages API rejects the seed parameter")
    }

    func test_claude_3_5_sonnetDoesNotAdvertiseThinking() {
        let manifest = CloudModelManifestTable.claude(modelName: "claude-3-5-sonnet-20241022")
        XCTAssertFalse(manifest.supportsThinking,
                       "Claude 3.5 Sonnet predates extended thinking")
    }

    func test_claude_3_7_sonnetSupportsExtendedThinking() {
        let manifest = CloudModelManifestTable.claude(modelName: "claude-3-7-sonnet-20250219")
        XCTAssertTrue(manifest.supportsThinking,
                      "Claude 3.7 Sonnet introduced extended thinking")
    }

    func test_claude_unknownModel_returnsUnknownManifest() {
        let manifest = CloudModelManifestTable.claude(modelName: "unrecognised-claude")
        XCTAssertEqual(manifest.modelIdentifier, "unrecognised-claude")
        XCTAssertEqual(manifest.contextWindow, 8192,
                       "Unknown models fall back to the conservative 8k default")
        XCTAssertFalse(manifest.supportsThinking)
    }

    // MARK: - Longest-prefix-wins ordering invariants

    func test_longestPrefixWins_specificBeatsGeneric() {
        // `claude-sonnet-4-7` is in the table; `claude-sonnet` is a less-specific
        // catch-all also in the table. The lookup must return the more specific
        // entry's manifest.
        let v47 = CloudModelManifestTable.claude(modelName: "claude-sonnet-4-7-20260101")
        XCTAssertEqual(v47.modelIdentifier, "claude-sonnet-4-7",
                       "claude-sonnet-4-7 is longer than claude-sonnet-4 / claude-sonnet — must win")
        XCTAssertEqual(v47.contextWindow, 1_000_000,
                       "Claude Sonnet 4.7 advertises a 1M context window via the table")
    }
}
