# LocalImage — Phase 4 (iPhone Deploy) — iteration 1

**Date**: 2026-06-07
**MK version**: 0.44.0
**Agent model**: Sonnet 4.6 (single run — physical device constraint; 3-run parallelism not applicable)
**App outcome**: **build + install + cert trust succeeded; model load BLOCKED — `MLXDiffusionBackend.loadModel()` OOM on FP32 unet (9.6 GB, 4–5 GB usable RAM). No viable iPhone model path in MK today (see #1691).**

## Why a single run

Brief 4 deploys to one physical iPhone. Running three parallel agents against the same device would produce signing conflicts and Metal/microphone races. Future runs of this brief should also be single-agent.

## Run summary

| Step | Status | Notes |
|---|---|---|
| Package resolution | PASS | Clean first attempt, no manual intervention |
| Swift compilation | PASS | One `@Sendable` fix on a download progress closure |
| Code signing | PASS (after fix) | Team ID mismatch in RUN-CONFIG (see F-01) cost ~10 min |
| `xcodebuild install` | PASS | `** INSTALL SUCCEEDED **` |
| First launch on device | PASS | Cert trust dance completed (Settings > General > VPN & Device Management > Trust) |
| Model download | BLOCKED | FP32 unet 9.6 GB — OOM during URLSession temp write; foreground URLSession also stops on screen lock (#1692) |
| Model load | BLOCKED | `MLXDiffusionBackend.loadModel()` OOM — 9.6 GB FP32 unet, 4–5 GB usable RAM (#1691) |
| Background download | NOT TESTED | Foreground URLSession — would pause on backgrounding (#1692) |
| Voice on real mic | NOT TESTED | |
| Image generation on-device | NOT TESTED | |
| Save to Photos | NOT TESTED | |
| History persistence | NOT TESTED | |
| Screenshots | NOT CAPTURED | `idevicescreenshot` broken on Xcode 26 |

**Phase 3 comparison signal:** The Swift API surface (MLXDiffusionBackend, VoiceConversationController) translated identically from macOS to iOS. All friction was in the iOS deployment layer or in doc gaps that were already present in phase 3.

---

## Finding buckets

### Both phases — MK doc gaps

These surfaced in phase 4 but are present in any MK consumer trying image gen; phase 4 just amplified them.

#### F-03 · P1 · DOC-MISSING — `MLXDiffusionBackend` has no standalone quickstart example

`QUICKSTART-IMAGE-GEN.md` demonstrates only `FluxDiffusionBackend` end-to-end. `MLXDiffusionBackend` (SDXL-Turbo) is the right choice for iPhone and has no walkthrough. The doc header says "Apple Silicon Mac" which a developer reads as "iOS not supported." Both backends' `register*` methods are listed in §3 but their module location (`ManifoldMLX`) is not stated — importing `ManifoldInference` only gets the protocol.

**Fix:** Add a `MLXDiffusionBackend` (SDXL-Turbo) end-to-end example to QUICKSTART-IMAGE-GEN.md marked as the recommended iPhone path.

#### F-04 · P1 · DOC-MISSING — Platform note misleadingly implies image gen is Mac-only

The QUICKSTART-IMAGE-GEN.md opening note reads "Apple Silicon Mac (FLUX.1 Schnell needs ~7 GB of unified memory headroom)." This is accurate for Flux but creates a false impression that image gen as a whole is macOS-only. `MLXDiffusionBackend` runs on iOS 18+.

**Fix:** Split the platform note per backend: "FluxDiffusionBackend: macOS 15+ only (~7 GB RAM). MLXDiffusionBackend: iOS 18+ / macOS 15+."

#### F-06 · P2 · DOC-MISSING — `@Sendable` requirement for progress callbacks not mentioned

The Swift 6 `@Sendable` constraint on closures crossing actor boundaries (e.g. a download progress handler passed into `@MainActor` `AppState`) isn't called out in QUICKSTART-IMAGE-GEN.md or QUICKSTART-VOICE.md. Phase 4 surfaces it more often because of the download progress + actor-isolated state machine combination.

**Fix:** Add a one-line note to both quickstarts: "When passing progress callbacks from non-isolated code into a `@MainActor` observable, annotate the closure `@Sendable`."

---

### Phase 4 only — iOS deployment friction

These are iOS ecosystem friction, not MK API issues. Only some have MK-actionable fixes.

#### F-01 · P1 · IOS-DEPLOYMENT — Team ID discovery: cert ID ≠ Xcode personal team ID

`security find-identity -v -p codesigning` returns the development certificate's team ID (`RDR4DZMS9Y`); this is **not** the same as the Xcode Personal Team ID that has provisioning authority (`YHX2HHZ52Y`). Using the cert's ID produces "No Account for Team / No profiles found." The brief says "10-char team ID from Xcode > Settings > Accounts" but a developer reaching for `security find-identity` (the natural shell path) will get the wrong value.

**Note:** This was a brief instrumentation bug in this run — the RUN-CONFIG.md was pre-filled with the cert team ID. The correct extraction command is:
```bash
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -o '"[A-Z0-9]\{10\}"' | head -1
```

**Fix:** Update the brief to add this command and explicitly warn that the cert team ID ≠ the Xcode provisioning team ID.

#### F-02 · P1 · IOS-DEPLOYMENT — Cert trust dance navigation path missing; error message is opaque

After install, `xcrun devicectl device process launch` fails with "has an invalid code signature ... or its profile has not been explicitly trusted by the user." The brief mentions the trust dance but not the exact path (`Settings > General > VPN & Device Management > [Apple Development: you@email.com] > Trust`). Multi-minute confusion spiral for a first-timer.

**Fix:** Add the exact navigation path and note that the Xcode alternative (Product > Run) shows a trust prompt inline.

#### F-05 · P2 · IOS-DEPLOYMENT — `idevicescreenshot` broken on Xcode 26

`idevicescreenshot` fails: "Could not start screenshotr service: Invalid service / Remember that you have to mount the Developer disk image." The `screenshotr` service was deprecated in Xcode 17+. `xcrun devicectl` has no screenshot subcommand. The only working path is: device side button + volume up, AirDrop to Mac.

**Fix:** Update the brief's screenshot section — remove `idevicescreenshot` guidance for Xcode 16+; document the manual capture path.

#### F-07 · P2 · IOS-DEPLOYMENT — `--start-stopped` in the brief's launch command is confusing post-cert-trust

The brief gives `xcrun devicectl device process launch --start-stopped` as the launch command. The flag is for debugger attachment, not for cert issues. A developer hitting the trust error and retrying with `--start-stopped` doesn't see any improvement — the flag is orthogonal to trust.

**Fix:** Remove `--start-stopped` from the default launch command in the brief; add a note that `--start-stopped` is for debugger attachment only.

#### F-08 · P2 · DOC-MISSING — `HuggingFaceDownloadService` background download behavior undocumented

`HuggingFaceDownloadService` uses foreground `URLSession` — a 1.4 GB model download will be paused by iOS when the app backgrounds. The brief's acceptance criteria include "survives at least one app backgrounding," but the current MK API doesn't provide a resumable background URLSession path. It's also unclear whether `BGTaskSchedulerPermittedIdentifiers` is needed in Info.plist.

**MK gap (more than iOS friction):** For a download of this size on cellular, foreground-only is a meaningful gap. This is the one phase 4 finding with a potential MK API fix.

**Fix (doc):** State in QUICKSTART-IMAGE-GEN.md that `HuggingFaceDownloadService` uses foreground URLSession and does not survive backgrounding; recommend keeping the app in foreground during download.

**Fix (API, longer term):** Add a background URLSession transfer path to `HuggingFaceDownloadService`.

---

## Concordance map

| Finding | Bucket | Severity | Actionable fix |
|---|---|---|---|
| F-03 MLXDiffusionBackend no quickstart | Both phases | P1 | QUICKSTART-IMAGE-GEN.md iPhone example |
| F-04 "Mac only" platform note misleads | Both phases | P1 | Split platform note per backend |
| F-06 `@Sendable` callbacks undocumented | Both phases | P2 | One-line note in quickstarts |
| F-01 Team ID: cert ≠ provisioning team | Phase 4 only | P1 | Brief + extraction command fix |
| F-02 Cert trust dance path missing | Phase 4 only | P1 | Add exact navigation path to brief |
| F-05 `idevicescreenshot` broken | Phase 4 only | P2 | Update brief screenshot section |
| F-07 `--start-stopped` misleading | Phase 4 only | P2 | Remove from default launch command |
| F-08 Background download — foreground URLSession stops on screen lock | Phase 4 only | P1 | Background URLSession path (#1692) |
| F-09 Progress fires per-file, not per-chunk | Both phases | P1 | `HuggingFaceDownloadService` byte-level progress (#1692) |
| F-10 No viable iPhone model — FP32 OOM; diffusionkit layout unsupported | Phase 4 only | **P0** | Diffusionkit support + iPhone model catalog entry (#1691) |

## Why brief 4 cannot pass today

iPhone image gen has no working end-to-end path in MK:

- Bundled downloader only supports diffusers layout → only model available is `stabilityai/sdxl-turbo` FP32 (9.6 GB unet)
- iPhone 16 Pro Max has 4–5 GB usable RAM for inference — model load fails with OOM (confirmed by pushing model directly via USB)
- iPhone-appropriate models (FLUX.1 Schnell 4-bit, ~1–2 GB) use diffusionkit layout → bundled downloader explicitly rejects them

This is not a configuration problem. Brief 4 cannot produce a passing run until MK adds diffusionkit layout support + a curated iPhone model entry. Tracked in #1691.

---

## What this run validated

1. **MK's public Swift API translates cleanly to iPhone.** One Swift 6 fix (`@Sendable` closure), zero API friction, zero compile errors from the MK surface. The same patterns from macOS phase 3 work on iOS.
2. **The deployment barrier is iOS ecosystem friction, not MK.** Provisioning, cert trust, broken tooling — these are the dominant cost for a first-time iOS deployer. A developer with prior iOS experience would skip F-01/F-02 entirely.
3. **Background download is a real gap for iPhone.** A multi-GB model download that pauses when the user locks their phone is a blocking UX problem. `HuggingFaceDownloadService` uses foreground URLSession and doesn't solve this. Tracked in #1692.
4. **iPhone image gen has no working end-to-end path.** The "Apple Silicon Mac" framing in `QUICKSTART-IMAGE-GEN.md` turns away iOS developers, and the one supported model (FP32 SDXL-Turbo, 13 GB) can't load on iPhone at all. iPhone-appropriate models use an unsupported layout. Tracked in #1691, #1693.

## Recommended next steps

**Gating (brief 4 cannot re-run without these):**
- #1691 — diffusionkit layout support + iPhone model catalog entry (WWDC-gated; wait for Core AI signal June 8)
- Brief 04 instrumentation fixes (no issue): team ID extraction command, cert trust nav path, `idevicescreenshot` deprecation, `--start-stopped` clarification

**Follow-on once #1691 lands:**
- #1692 — `HuggingFaceDownloadService` background URLSession + per-chunk progress

**Independent doc fix (can ship now):**
- #1693 — `QUICKSTART-IMAGE-GEN.md` iPhone framing: split Mac/iPhone platform note, add `MLXDiffusionBackend` Mac example, storage/RAM callouts
