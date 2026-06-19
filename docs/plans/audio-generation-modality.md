# Audio-generation modality (the 3rd media modality for P4)

**Status:** direction set 2026-06-14 · **Decision owner:** @roryford

## Decision

- **Core ships TTS** as the concrete audio-generation modality: text → spoken-audio
  *artifact*, one-shot, riding the `MediaGeneration<Output>` seam (`.progress` → optional
  `.preview` → `.completed`, stored as a `generatedMedia` `MessagePart`).
- **Music gen is NOT shipped by core.** Too much surface (model zoo, licensing, diffusion
  weights). Instead, **leave the door open**: the generic seam is the extension point, so a
  **consumer or companion** can define a music backend (Stable Audio Open locally, Lyria via
  cloud) without forking core.
- **Real-time/duplex** music (Magenta RealTime 2) stays out — different live-session
  lifecycle, belongs with the realtime-voice surface (#1415).
- **Pushing impls to companions is fine** — core owns the contract + (optionally) a zero-dep
  Apple reference backend; heavy model impls live in companions.

## Why this *confirms* P4 (not shrinks it)

"Let consumers define music" is only possible if `MessagePart` has a **generic**
`generatedMedia(GeneratedMediaPayload)` case rather than hardcoded per-modality cases. A
fixed `generatedAudio` case would leave a consumer's music output nowhere to persist/render.
So:

- **TTS is the in-core proof** of the generic seam.
- **Music is the out-of-tree modality** that exercises the acceptance metric *"a new modality
  lands in ≤3 EDGE files"* — now load-bearing, not theoretical.

P4 proceeds. The seam (P4a) is the extensibility contract; the collapse (P4b/P4c) is what
makes the extension point real.

## Shape

- `AudioGeneration = MediaGeneration<AudioOutput>` (one-shot), parallel to `ImageGeneration`
  / `VideoGeneration`. A real typealias, not a stub.
- `GeneratedMediaPayload` carries audio (file URL + format + duration + sample rate). This is
  the shape a consumer's music backend reuses — same payload, different backend + config.
- `SpeechGenerationConfig` (text, voice, rate, pitch…) is the core-shipped config. Music
  config is defined by whoever ships the music backend.

## TTS model picks (local-first; companions OK)

| Tier | Option | License | Platform | Placement |
|------|--------|---------|----------|-----------|
| Zero-dep reference | **Apple `AVSpeechSynthesizer`** (+ Personal Voice) | none (OS) | macOS + iOS | could ship **in core** — no external dep |
| High-quality local | **Kokoro** via `Blaizzy/mlx-audio-swift` | Apache-2.0 (clean) | macOS + iOS | **companion** (mlx-audio dep) |
| Conversational | **CSM** via mlx-audio-swift | ⚠️ verify | macOS + iOS | companion |
| Cloud | a cloud TTS provider | n/a | all | `ManifoldCloudSaaS` |

Apple `AVSpeechSynthesizer` is the natural zero-dependency reference backend (proves the seam
end-to-end with no model download); Kokoro/CSM via mlx-audio-swift are the quality upgrades
and live in a companion.

## TTS / ManifoldVoice boundary — RESOLVED (2026-06-14)

There are **three distinct lanes**; they share TTS *engines* but not protocols. Resolved by
reading the actual `ManifoldVoice` surface (`SpeechSynthesizing.speak(_:) async` /
`stopSpeaking()` — ephemeral playback, no output, driven by `VoiceConversationController`).

| Lane | Surface | Output | Lifecycle | Owner |
|------|---------|--------|-----------|-------|
| **1 — Live voice I/O** | `ManifoldVoice` (`SpeechSynthesizing`, `SpeechTranscribing`, wake word, `VoiceConversationController`) | none — plays to speaker | `speak`/`stop`, fire-and-forget | exists today, **stays** |
| **2 — Audio artifact gen** | **P4** `AudioGeneration = MediaGeneration<AudioOutput>` (TTS + consumer music) | persisted file (`GeneratedMediaPayload`) | `.progress` → `.completed` stream, stored as `generatedMedia` | **new (this design)** |
| **3 — Realtime full-duplex voice agent** | a `VoiceBackend`-style streaming protocol (OpenAI-Realtime-style) | live bidirectional stream | continuous duplex session | **#1415** (parking-lot) |

**Resolution:** P4 TTS does **not** absorb or supersede `ManifoldVoice`. Lane 1 (interact)
and Lane 2 (generate-artifact) are different contracts — one plays audio, one renders audio
to a file with a progress stream. **Share the engine, not the protocol:** a single TTS engine
adapter (Apple `AVSpeechSynthesizer`, Kokoro, …) can back *both* `SpeechSynthesizing.speak`
(Lane 1, via `AVSpeechSynthesizer` playback) *and* the Lane 2 media backend (via
`AVSpeechSynthesizer.write(_:toBufferCallback:)` → file). The protocols stay separate because
the roles differ. Lane 3 (#1415) is a third surface, unrelated to both.

### Remaining sub-decisions (resolve before P4 implementation)
- [ ] **Core reference backend?** Ship Apple `AVSpeechSynthesizer` as an in-core audio backend
  (zero-dep, proves the seam), or keep core contract-only and put even the Apple backend in a
  module/companion?
- [ ] **Companion home for mlx-audio TTS** — add to `manifold-mlx`, or a new `manifold-audio`
  companion (keeps mlx-audio-swift out of the diffusion package).
- [ ] **Music extension example** — ship a doc/sample showing a consumer wiring a music
  backend onto the seam (proves the ≤3-EDGE-files claim), even though core doesn't ship music.

## Consequence for the cleanup train

P4 is **not deferred** (see `pre-1.0-api-cleanup-train.md` §B1). P4a (additive seam, real
`AudioGeneration` typealias + `SpeechGenerationConfig`) lands non-breaking; P4b/P4c (collapse
+ delete clones) ship as a **lockstep ManifoldKit + manifold-mlx release**. Core's only audio
*backend* is optionally Apple `AVSpeechSynthesizer`; everything heavier is companion/consumer.
