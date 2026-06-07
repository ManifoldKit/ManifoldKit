# Brief: LocalImage — iPhone Design-to-App, On-Device End-to-End

You are a Swift developer evaluating **ManifoldKit** as the foundation for a small iPhone app. A designer has handed you a flow file describing a voice-driven, on-device image-generation app. Your job is to take that design and ship it as a working app **on your actual iPhone** — not the simulator.

This is the highest-fidelity DX exercise in the series. Phase 3 ran the same design as a macOS app to isolate signal about MK's public API. Phase 4 adds the iPhone-deployment surface on top: iOS-specific APIs, code signing, on-device download, real microphone, real Metal on A-series silicon, real share sheet, real Photos save.

## Why this is a manual, periodic run

- Requires a physical iPhone (iOS Simulator can't run Metal-backed MLX diffusion; voice in simulator is unreliable)
- Requires code signing and a trusted developer profile on the device
- Costs ~90–120 minutes of focused time including cold build + device install
- Not CI-friendly — there is no good way to drive a physical device from GitHub Actions

Run this **pre-release** or on a periodic cadence (e.g. monthly), not per-PR. The goal is honest signal about whether a vibe-coder can ship a ManifoldKit-powered app to their phone in a sitting.

## Pre-flight checklist (developer to complete before starting)

Before invoking the agent, the developer needs to have:

- [ ] A physical iPhone running iOS 26+ connected via USB or Wi-Fi pairing
- [ ] Developer Mode enabled on the iPhone (`Settings > Privacy & Security > Developer Mode`)
- [ ] An Apple ID / Personal Team signed into Xcode (free tier works for personal/dev installs)
- [ ] Xcode 26+ installed
- [ ] `xcrun devicectl list devices` shows the iPhone in the output
- [ ] *(Optional but recommended)* `brew install libimobiledevice` so the agent can capture screenshots via `idevicescreenshot`. Without it, you'll capture screenshots manually from the device.

Fill in your specifics in `./RUN-CONFIG.md` at the start of the run (template below). **Do not commit `RUN-CONFIG.md` to the public repo** — it contains your device UDID and team ID. It's gitignored by default under `runs/`.

## What you're building

**LocalImage** — a native SwiftUI **iOS** app that:

1. Greets the user on first launch with a clear "we need to download a model" moment, downloads a diffusion model in the background (resumable, survives backgrounding), and persists it locally
2. Lets the user describe an image **by voice** (the design's primary input mode) or by typing
3. Generates a 768×768 image on-device via MLX diffusion on Apple silicon
4. Shows the generated image with Save (to Photos) / Share (iOS share sheet) / Try again / Refine
5. Keeps a history of prompts + generated images across launches

## The design inputs

Same bundle as phase 3 — all in `./design-assets/` (sibling to this brief):

1. **`DESIGN-BRIEF.md`** — prose design brief
2. **`LocalImage Flow.html`** — runnable iPhone-framed flow viewer:
   ```
   open scripts/dx-walkthrough/briefs/03-design-assets/"LocalImage Flow.html"
   ```
3. **`screens.jsx`** — every screen as a named React component with concrete copy and state

For phase 4 the **iPhone screens are the primary visual reference** (not the `Mac` variant). The design is iPhone-first; this is where you ship it the way the designer intended.

## Constraints

- **Target**: iOS 26, Swift 6, SwiftUI, native iOS app deployed to a physical iPhone
- **You may read**:
  - ManifoldKit's `README.md`, `docs/`, `Sources/*/Documentation.docc/`, `Package.swift`, repo-root markdown
  - The `Example/Examples/MinimalExample/` directory if one exists
  - Everything in `./design-assets/`
- **You may NOT read**:
  - ManifoldKit's source files (`Sources/Manifold*/**/*.swift`) or its tests (`Tests/**`)
  - Any other LocalImage implementation on this machine
- **Backend**: image gen is `MLXDiffusionBackend`. Voice via the voice module. Choose what the docs guide you toward.
- **Budget**: 90–120 minutes. First-time-on-device install + trust dance + cold MK build will eat 15–20 minutes of that before you write meaningful app code.
- **Signing**: use the developer's Personal Team / Apple ID (in `RUN-CONFIG.md`). On first install the developer will need to trust the certificate on the device (`Settings > General > VPN & Device Management`).

## RUN-CONFIG.md template

Create this at the start of your run. **Do not commit it.** The agent reads it for device-specific values.

```markdown
# Run config — phase 4 (iPhone)

DEVICE_NAME: <e.g. "Rory's iPhone">
DEVICE_UDID: <from `xcrun devicectl list devices`>
TEAM_ID: <10-char provisioning team ID — NOT the cert team ID from `security find-identity`. Get it with:
         defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -o '"[A-Z0-9]\{10\}"' | head -1>
BUNDLE_ID: <e.g. com.example.localimage — must be unique to your team>
HAS_LIBIMOBILEDEVICE: <true|false>
```

## Working directory

Your app lives at `./app/` relative to this brief's run directory. You'll need an **Xcode project** (not pure SwiftPM exec) so you can configure Info.plist, signing, and a device-deployable scheme. Reference ManifoldKit via a local path package:

```swift
.package(name: "ManifoldKit", path: "<absolute path to the ManifoldKit repo containing this brief>")
```

## Info.plist keys you'll need

The voice path almost certainly needs these. Photos save needs the third. If MK's docs tell you which keys to add, follow the docs; if they don't, that's a friction entry.

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `NSPhotoLibraryAddUsageDescription`

## Build & deploy commands

The agent should drive the device install via `xcodebuild`. Typical shape:

```bash
xcodebuild \
  -project app/LocalImage.xcodeproj \
  -scheme LocalImage \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -allowProvisioningUpdates \
  install
```

After install, launch via:

```bash
xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  <bundle-id>
```

If the launch fails with "has an invalid code signature ... has not been explicitly trusted by the user", complete the cert trust dance on-device: **Settings > General > VPN & Device Management > [Apple Development: your@email.com] > Trust**. Then re-run the launch command. (`--start-stopped` is for debugger attachment only — it does not affect trust resolution.)

If `xcodebuild install` fails on signing, fall back to opening the project in Xcode and hitting Run — log every signing-related friction step.

## Required behavior (acceptance criteria)

- [ ] App builds and installs on the physical iPhone (not simulator)
- [ ] App launches and the launch screen / first-run state appears
- [ ] First-run model download starts, makes progress, and survives at least one app backgrounding (lock the phone for 30s, return, download resumes)
- [ ] Voice input works on real mic: tap mic, speak, transcription appears in prompt
- [ ] Image generation produces a 768×768 PNG on-device (no cloud calls during gen — verify with Charles/Proxyman if you have it, or just by airplane-moding the phone before generation)
- [ ] Generated image can be saved to Photos
- [ ] After force-quitting and relaunching, history persists
- [ ] Capture screenshots of: first-launch, download, voice-listening, generating, result, history

## Screenshot capture

`idevicescreenshot` (libimobiledevice) is **broken on Xcode 16+** — the `screenshotr` service was deprecated and `xcrun devicectl` has no screenshot subcommand.

Capture screenshots manually: **side button + volume up** on the device, then AirDrop to the run directory. Set `HAS_LIBIMOBILEDEVICE: false` in RUN-CONFIG.md regardless of whether the tool is installed.

## Deliverables

1. **`./app/`** — Xcode project
2. **`./FRICTION.md`** — friction log (same template as phase 3, with category `IOS-DEPLOYMENT` added)
3. **`./session.log`** — final build / install / launch output
4. **`./screenshots/`** — the 6 screen captures listed above
5. **`./NOTES.md`** — 10–15 lines covering: iOS-specific MK surface (Info.plist, background download, file protection, share sheet integration), what worked vs phase 3's mac run, what got harder, your verdict on shipping an MK app to a real iPhone

**`./RUN-CONFIG.md` is private — leave it out of any committed artefact.**

## FRICTION.md categories (extended for phase 4)

In addition to phase 3 categories (DOC-MISSING, DOC-WRONG, API-DISCOVERABILITY, API-ERGONOMICS, API-GAP, DESIGN-VS-API-MISMATCH), use:

- `IOS-DEPLOYMENT` — signing, provisioning, device trust, Info.plist key discovery, scheme configuration
- `IOS-RUNTIME` — anything that worked on mac in phase 3 but breaks on device (jetsam, file protection, background lifecycle, mic permissions)

## What we're trying to learn (phase 4 vs phase 3)

Phase 3 isolated MK's public API on a forgiving target. Phase 4 layers iOS deployment on top. The comparison is the point:

- **Findings present in both phases** → MK public API issues
- **Findings only in phase 4** → MK iOS-specific gaps (Info.plist docs missing, background download fragile, jetsam not handled, share-sheet integration awkward, etc.)
- **Findings phase 3 had that phase 4 didn't** → mac-specific quirks that don't matter for the iPhone story

Be specific about which bucket each entry falls into.

## Reporting back

When done (or when time/attempts are exhausted), respond with:
- Whether the app works on device (yes / no / partially) — call out specifically: did device install succeed? did the cert trust dance work? did background download survive? did voice work on real mic? did Photos save work?
- Path to your run directory
- The 3 highest-severity friction entries, verbatim, with their phase-3-vs-4 bucket noted
- One-line overall verdict on shipping an MK-powered app to an actual iPhone in a single sitting
