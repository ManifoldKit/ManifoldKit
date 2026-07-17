# App Store submission checklist

**Audience:** consumer
**Status:** living

This is the indie-developer checklist for shipping a ManifoldKit-backed app
to the App Store. It assumes you have already chosen a build profile (see
README §2 "Build modes"). Every item here is something Apple's review
automation either checks directly or flags for human review.

If you're targeting iOS 26+ / macOS 26+ exclusively and using only Apple
Foundation Models, see the **core-only fast path** at the end — most
of the items below collapse to a single answer. (The former `FoundationOnly`
trait was retired in v0.48: core now has no heavy ML dependencies at all, so
the lean build is simply "don't add the companion packages".)

## 1. Encryption export classification

Every app submitted to the App Store must answer the encryption-export
question. ManifoldKit does not ship its own crypto, but it uses HTTPS for cloud
backends. That counts as encryption under U.S. export law.

- **Offline build** (Foundation Models and/or local companion-package
  inference only, no cloud endpoints used): set
  `ITSAppUsesNonExemptEncryption=false` in your `Info.plist`. No further
  filing needed.
- **Cloud backends linked in** (always compiled since v0.48; linked unless you exclude the cloud products): set
  `ITSAppUsesNonExemptEncryption=true` and complete the annual
  self-classification form on App Store Connect. Most developers qualify
  for the "uses encryption only for app-specific authentication and HTTPS
  to a server" exemption — see Apple's
  [encryption export documentation](https://developer.apple.com/documentation/security/complying_with_encryption_export_regulations).

```xml
<!-- Info.plist for offline builds -->
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

## 2. Privacy manifest

Apple requires `PrivacyInfo.xcprivacy` for any app that uses
required-reason APIs (which ManifoldKit does — `UserDefaults`, file timestamps,
disk-space queries).

- Copy `Templates/PrivacyInfo.xcprivacy` from this repo into your app
  target's resources.
- Review each `NSPrivacyAccessedAPIType` entry; remove ones for features
  you compile out (the file is annotated with the triggering ManifoldKit feature).
- See `Templates/PrivacyInfo.xcprivacy.README.md` for the full reference.

ManifoldKit's privacy posture is **zero tracking, zero data collection, zero
tracking domains** by default. The template's `NSPrivacyTracking=false`
and empty `NSPrivacyTrackingDomains`/`NSPrivacyCollectedDataTypes` arrays
reflect that. If your app adds analytics or tracking, populate those
arrays accordingly — your additions are layered on top of ManifoldKit's posture,
not in place of it.

## 3. App Transport Security

Default ATS is fine for SaaS-only and offline builds. You only need
an exception block if you bundle a localhost Ollama instance or talk to
unencrypted self-hosted endpoints.

```xml
<!-- Info.plist — only needed if you ship localhost Ollama -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>localhost</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <false/>
        </dict>
    </dict>
</dict>
```

App Review will ask about ATS exceptions during a manual review pass.
Justify with: "the app talks to a user-installed Ollama daemon at
`http://localhost:11434`; the address is loopback-only and never reaches
the network." Apple has approved this pattern for other on-device LLM
shells.

## 4. Microphone / speech entitlements (ManifoldVoice consumers only)

If your app depends on the `ManifoldVoice` product (the former `Voice`
trait was retired in v0.48), add both usage-description strings.
Apps that don't link `ManifoldVoice` should not ship these keys.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice chat input. Audio is transcribed on-device and never sent to a server.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Transcribes your voice into chat input. Transcription runs on-device.</string>
```

The default Apple speech transcriber returns a user-facing error on the
simulator, so validate the real capture flow on device or macOS hardware
before submission.

## 5. iOS 18 vs iOS 26 deployment targeting

`FoundationBackend` requires iOS 26 / macOS 26. If your app's deployment
target is iOS 18, you must gate the Foundation Models code path at runtime
and fall back to a different backend (or surface a "Foundation Models
require iOS 26" placeholder) on iOS 18 devices.

```swift
import ManifoldFoundation

if FoundationBackend.isAvailable {
    vm.loadFoundationModelIfAvailable()
} else {
    // iOS 18 fallback: surface a different backend (Llama, Ollama, cloud)
    // or a "Update to iOS 26 for on-device Apple intelligence" placeholder.
}
```

`loadFoundationModelIfAvailable()` is a no-op on iOS 18 — it returns
without throwing — so it's safe to call unconditionally if you'd rather
let users without iOS 26 see the regular load failure UI.

## 6. App Store review claims

If your marketing copy mentions "private", "on-device", "no telemetry",
or similar privacy claims, App Review may ask for substantiation. The
defensible claim shape, when accurate for your build:

> Inference runs on-device via Apple Foundation Models / MLX / llama.cpp.
> The chat framework (ManifoldKit, MIT-licensed) ships with zero analytics
> and zero outbound network by default; see
> https://github.com/ManifoldKit/ManifoldKit and the bundled
> `PrivacyInfo.xcprivacy` for the audited surface.

Pointing reviewers at ManifoldKit's `Templates/PrivacyInfo.xcprivacy`, the public
source, and the [SECURITY.md](../SECURITY.md) threat-model doc usually
clears review questions in the first round.

## 7. Bundle size estimate

ManifoldKit's overhead in your final IPA varies by which packages you add:

| Profile | ManifoldKit overhead | Notes |
|---------|--------------|-------|
| Core only (Foundation Models + cloud) | ~10 MB | No heavy ML dependencies at all — the lean build is the default since v0.48. Includes OpenAI / Claude / Ollama clients (MB-scale text). |
| Core + `manifold-llama` | ~570 MB checkout | The companion pins the ~563 MB prebuilt llama.cpp xcframework. |
| Core + `manifold-mlx` | ~100 MB+ checkout | mlx-swift source checkout + Metal shaders. |

The companion figures are checkout sizes; what lands in your IPA is
smaller after dead-code stripping but still substantial. If your app
targets only Apple Foundation Models (and/or cloud), don't add the
companion packages — core builds with no MLX or llama.cpp checkout at
all, which is the strongest "link-out" guarantee: there are no MLX or
llama.cpp symbols to strip because the dependencies are never resolved.
(This replaces the pre-v0.48 `FoundationOnly` trait and its symbol-audit
CI gate — compile-out became link-out, and link-out became
"not-even-resolved".)

## 8. SwiftPackageIndex submission (maintainer / out-of-tree)

Submitting ManifoldKit to the [Swift Package Index](https://swiftpackageindex.com)
is a one-time maintainer task and lives outside this repo. The steps:

1. Fork [`SwiftPackageIndex/PackageList`](https://github.com/SwiftPackageIndex/PackageList).
2. Add `https://github.com/ManifoldKit/ManifoldKit.git` to `packages.json`,
   keeping the file alphabetically sorted.
3. Open a PR against `SwiftPackageIndex/PackageList`.
4. After merge, update GitHub repo metadata:
   - Topics: `swift, ios, macos, llm, foundation-models, mlx, llama-cpp,
     on-device-ai, swiftui`
   - Homepage: the SPI-generated DocC URL once it's live.
   - Enable Discussions for community Q&A.

This checklist covers it from the consumer side — if you're shipping a
ManifoldKit-based app, you don't need to do this; the maintainer handles the
PackageList submission once.

---

## Core-only fast path

For indie iOS 26+ / macOS 26+ apps using only Apple Foundation Models, the
checklist collapses to:

1. **Package**: depend on ManifoldKit alone — do **not** add the
   `manifold-mlx` / `manifold-llama` companion packages. Core has no heavy
   ML dependencies since v0.48 (this replaces the retired `FoundationOnly`
   trait).
2. **Encryption export**: `ITSAppUsesNonExemptEncryption=false`.
3. **Privacy manifest**: copy `Templates/PrivacyInfo.xcprivacy`. You can
   drop the `NSPrivacyAccessedAPICategoryDiskSpace` and
   `NSPrivacyAccessedAPICategoryFileTimestamp` entries if you don't ship
   any model-storage UI; keep `NSPrivacyAccessedAPICategoryUserDefaults`.
4. **ATS**: defaults are fine.
5. **Microphone / speech**: not needed (don't link `ManifoldVoice`).
6. **Deployment target**: iOS 26 / macOS 26 minimum.
7. **Bundle size**: MB-scale ManifoldKit overhead — no MLX / llama.cpp
   material is even resolved, let alone linked.

That's the full submission surface. ManifoldKit does not add tracking, analytics,
identity-API access, or cross-app data sharing in this configuration.
