# PrivacyInfo.xcprivacy template

Apple requires a privacy manifest for App Store submission. This template
covers the on-device system APIs BaseChatKit touches by default.

## How to use it

1. Copy `Templates/PrivacyInfo.xcprivacy` into your app target's resources.
   In Xcode: drag the file into your project navigator, then ensure it is
   listed under **Build Phases → Copy Bundle Resources** for the app target.
2. Review the three `NSPrivacyAccessedAPIType` entries — each is annotated
   with the BCK feature that triggers it.
3. Remove entries for features you compile out:
   - `FoundationOnly` build with no model storage UI → drop the
     `NSPrivacyAccessedAPICategoryDiskSpace` and
     `NSPrivacyAccessedAPICategoryFileTimestamp` entries.
   - You hand-roll `UserDefaults`-free preference storage → drop
     `NSPrivacyAccessedAPICategoryUserDefaults`.
4. If your app collects telemetry, sends usage analytics, or links to any
   tracking SDK, populate `NSPrivacyTracking` and `NSPrivacyCollectedDataTypes`
   accordingly. BCK itself sets both to "no tracking" / "no collection" — the
   defaults in this template reflect BCK's posture, not yours.

## What BCK does *not* do

- No `NSPrivacyAccessedAPICategoryUserIdInfo` — BCK never reads identity APIs.
- No `NSPrivacyAccessedAPICategoryActiveKeyboards` — BCK doesn't enumerate
  keyboards.
- No `NSPrivacyAccessedAPICategorySystemBootTime` — BCK doesn't read boot time.
- No tracking domains. BCK has zero outbound network by default; cloud
  backends only fire when you wire `OpenAIBackend`/`ClaudeBackend`/`OllamaBackend`
  with explicit credentials. Foundation Models run entirely on-device.

## References

- [Apple — Describing use of required-reason API](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api)
- [`docs/AppStoreSubmission.md`](../docs/AppStoreSubmission.md) — full
  submission checklist including encryption-export classification, ATS
  exceptions, and bundle-size estimates per build profile.
