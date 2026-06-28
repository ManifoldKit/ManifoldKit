import Foundation
import ManifoldInference

/// Resolves whether the microphone composer control can be shown without
/// risking a host-process crash.
///
/// iOS hard-crashes the *host* app with a SIGABRT the moment the microphone
/// permission API (`AVAudioSession`) is invoked while `NSMicrophoneUsageDescription`
/// is missing from the app's `Info.plist` — and it does so *before* any
/// `try`/`catch` in our code can run, so the crash is unrecoverable from within
/// the framework. Because `ChatView` ships the mic button by default, a host
/// that forgot to declare the key would crash on first tap. This gate lets the
/// composer hide the button instead, turning an unrecoverable crash into a
/// benign no-op.
///
/// > Note: There is intentionally no equivalent gate for the photo-library
/// > buttons. They use `PhotosPicker`, which is PHPicker-backed and runs
/// > out-of-process — it neither requires `NSPhotoLibraryUsageDescription` nor
/// > SIGABRTs without it, so a plist guard there would only *regress* hosts that
/// > legitimately ship the picker without the key. Photo controls are gated on
/// > the ``ManifoldConfiguration/Features/showImageAttachment`` flag alone.
///
/// The bundle is injectable so tests can simulate a host whose `Info.plist`
/// lacks the key without touching the test bundle's own plist.
enum ComposerPermissionGate {

    /// Info.plist key iOS requires before any microphone permission request.
    static let microphoneUsageKey = "NSMicrophoneUsageDescription"

    /// Returns `true` when `key` is present as a non-empty string in `bundle`'s
    /// `Info.plist`. An empty or whitespace-only value is treated as absent
    /// because iOS rejects it the same way it rejects a missing key.
    static func usageDescriptionPresent(_ key: String, in bundle: Bundle = .main) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the audio-recording control should be shown: the host enabled it
    /// via ``ManifoldConfiguration/Features/showAudioInput`` *and* the microphone
    /// usage string is declared so a tap can't SIGABRT.
    static func shouldShowAudioInput(
        features: ManifoldConfiguration.Features,
        bundle: Bundle = .main
    ) -> Bool {
        features.showAudioInput
        && usageDescriptionPresent(microphoneUsageKey, in: bundle)
    }
}
