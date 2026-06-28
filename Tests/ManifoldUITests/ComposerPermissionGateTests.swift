import XCTest
@testable import ManifoldUI
@testable import ManifoldInference

/// Unit tests for ``ComposerPermissionGate`` — the helper that decides whether
/// the microphone composer control may be shown.
///
/// These cover the two linked behaviours: feature-flag gating and the
/// Info.plist-absent degradation guard that prevents a host SIGABRT when
/// `NSMicrophoneUsageDescription` is missing. A custom `Bundle` is injected so
/// we can simulate a host whose Info.plist lacks the usage-description key
/// without mutating the test bundle's own plist.
final class ComposerPermissionGateTests: XCTestCase {

    // The xctest bundle declares no usage-description keys, so it stands in for a
    // host whose Info.plist is missing NSMicrophoneUsageDescription.
    private var bundleWithoutKeys: Bundle { Bundle(for: ComposerPermissionGateTests.self) }

    // MARK: - usageDescriptionPresent

    func test_usageDescriptionPresent_falseWhenKeyMissing() {
        XCTAssertFalse(
            ComposerPermissionGate.usageDescriptionPresent(
                ComposerPermissionGate.microphoneUsageKey,
                in: bundleWithoutKeys
            ),
            "A bundle with no NSMicrophoneUsageDescription must report the key absent"
        )
    }

    // MARK: - shouldShowAudioInput

    func test_shouldShowAudioInput_falseWhenPlistKeyMissing_evenWhenFlagOn() {
        let features = ManifoldConfiguration.Features(showAudioInput: true)
        XCTAssertFalse(
            ComposerPermissionGate.shouldShowAudioInput(features: features, bundle: bundleWithoutKeys),
            "Mic button must be hidden when NSMicrophoneUsageDescription is absent, regardless of the flag — this is the SIGABRT guard"
        )
    }

    func test_shouldShowAudioInput_falseWhenFlagOff() {
        let features = ManifoldConfiguration.Features(showAudioInput: false)
        XCTAssertFalse(
            ComposerPermissionGate.shouldShowAudioInput(features: features, bundle: bundleWithoutKeys),
            "Mic button must be hidden when the showAudioInput flag is off"
        )
    }

    // MARK: - Positive path (key present + flag on)

    /// Proves the gate is a genuine `flag && key-present` AND, not a function
    /// that always returns false: with the usage string declared and the flag
    /// on, the control is shown.
    func test_shouldShowAudioInput_trueWhenFlagOnAndKeyPresent() throws {
        let bundle = try makeBundle(withInfoPlistKeys: [
            ComposerPermissionGate.microphoneUsageKey: "Record audio messages.",
        ])
        let features = ManifoldConfiguration.Features(showAudioInput: true)

        XCTAssertTrue(
            ComposerPermissionGate.shouldShowAudioInput(features: features, bundle: bundle),
            "Mic button must show when the flag is on and the usage string is declared"
        )
    }

    // MARK: - Helpers

    /// Builds a real on-disk `.bundle` whose Info.plist contains `keys`, so the
    /// positive path exercises `Bundle.object(forInfoDictionaryKey:)` for real.
    /// macOS bundles read Info.plist from `Contents/Info.plist`.
    private func makeBundle(withInfoPlistKeys keys: [String: String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldComposerGate-\(UUID().uuidString).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plistURL = contents.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: keys,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)
        guard let bundle = Bundle(url: root) else {
            throw XCTSkip("Could not construct a temporary bundle for the positive-path test")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return bundle
    }
}
