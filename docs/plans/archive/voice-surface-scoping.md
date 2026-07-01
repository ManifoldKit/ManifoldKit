# ManifoldVoice realtime / voice-agent surface — scoping note

**Status:** Design note / parking-lot exploration. No implementation.
**Issue:** #1415. **Date:** 2026-06-13.

A one-page scoping decision for whether (and how) ManifoldKit should grow a
production realtime / voice-agent surface. The conclusion is a recommendation,
not a commitment — see "Outcome" at the end.

## Current state (audit of `ManifoldVoice`)

`ManifoldVoice` today is a **half-duplex dictation + read-aloud accessory**, not
a realtime agent. The `Voice` trait was retired in v0.48 (PR A2); the module now
compiles unconditionally and depends on `ManifoldUI` (for the composer
accessory) — it does **not** depend on `ManifoldInference`.

What is wired (≈900 LOC, all functional):

- **STT** — `AppleSpeechTranscriber` (`SFSpeechRecognizer` + `AVAudioEngine`),
  on-device, with authorization/locale/simulator gating behind the
  `SpeechTranscribing` protocol.
- **TTS** — `AppleSpeechSynthesizer` (`AVSpeechSynthesizer`) behind
  `SpeechSynthesizing`.
- **Wake word** — `AppleWakeWordDetector` (transcript-substring match) behind
  `WakeWordDetector`.
- **Orchestration** — `VoiceConversationController` (`@Observable @MainActor`):
  start/stop/cancel recording, live transcript, wake-word toast lifecycle, and
  `togglePlayback(for:)` read-aloud.
- **UI** — `VoiceComposerAccessory` merges the final transcript into
  `ChatViewModel.inputText` (replace/append) and reads the last assistant reply
  aloud. `VoiceInputButton`, `LiveTranscriptionView`, `WakeWordToast`.

What is **not** present (the gap this note scopes):

- No full-duplex / barge-in loop. Recording and playback are mutually exclusive
  states on one controller.
- No streaming audio to/from a model. Voice never reaches `InferenceBackend` —
  it produces text that the *user* then sends through the normal chat path, and
  reads back text the model already produced.
- No realtime transport (no WebSocket / SSE / SIP). Grep for
  `Realtime`/`WebSocket` across `Sources/` returns nothing.
- No voice-specific session lifecycle, interrupt handling, or VAD beyond the
  coarse start/stop button.

In short: **speech I/O adapters + a composer accessory, exactly as CLAUDE.md
describes — and nothing more.** A genuine voice *agent* is greenfield.

## Market gap (issue premise)

As of mid-2026 there is no production-grade, native-Swift, open voice/realtime
*agent* SDK. The realtime ecosystem is JS/Python-first (OpenAI Realtime SDKs,
LiveKit/Pipecat agents). On Apple platforms developers hand-stitch
`SFSpeechRecognizer` + `AVSpeechSynthesizer` + a chat model, or reach for a
cross-platform RN/Flutter wrapper. A Swift-native, local-first voice loop that
plugs into an existing inference stack is an open niche — and one that is
directly on-thesis for a local-inference product.

## Transport options

| Option | Duplex | Latency | Privacy | Cost | Notes |
|--------|--------|---------|---------|------|-------|
| **Apple Speech + on-device TTS** (extend today's adapters into a loop) | Half→full (with VAD/barge-in work) | Low, no network | On-device, no cloud | Free | On-thesis. STT/TTS already shipped; missing piece is the loop + VAD. |
| **OpenAI Realtime API** (`gpt-realtime`, WebSocket or SIP) | Full | Low (server-side) | Cloud, audio leaves device | Per-minute | True speech-to-speech, server VAD/interrupt. New transport + ephemeral-key auth. |
| **Anthropic voice** | — | — | — | — | No first-party realtime voice surface to target as of this writing. **Deferred.** |

## Recommendation — first target

**Start local-first: build the realtime loop on the existing Apple Speech + TTS
adapters.** Rationale:

1. **On-thesis.** A no-cloud voice loop is the product's differentiator; it pairs
   with local model inference end-to-end.
2. **Lowest marginal cost.** STT/TTS/wake-word adapters already exist and are
   protocol-fronted — the new work is the duplex loop, VAD/barge-in, and the
   STT→`InferenceBackend`→TTS plumbing, not the I/O primitives.
3. **No new auth/transport surface.** Stays inside the existing security and
   networking boundaries.

**Offer OpenAI Realtime as the cloud option, second.** Because the recommended
architecture is a separate protocol (below), a `gpt-realtime` WebSocket
implementation slots in as an alternate `VoiceBackend` without disturbing the
local path. **Anthropic voice is deferred** until a first-party surface exists.

## Architecture decision — separate `VoiceBackend` protocol

**Recommend a new `VoiceBackend` protocol; do not overload `InferenceBackend`.**

`InferenceBackend` is request/response (or token-streamed): a prompt goes in, a
`GenerationEvent` stream comes out, and the call completes. A voice agent is
**full-duplex with a long-lived session**: continuous audio in *and* out
simultaneously, barge-in/interrupt, VAD-driven turn boundaries, and lifecycle
events (session open, speaking, listening, interrupted, closed) that have no
analogue in the text contract. Forcing this through `InferenceBackend` would
either distort that contract for every text backend or smuggle voice state into
config/event types.

A separate protocol (likely an `actor` or `@MainActor` session object exposing an
`AsyncStream` of voice-session events, plus audio-in / interrupt methods) keeps:

- the text contract clean (`ManifoldContract` unchanged);
- the local path and the OpenAI-Realtime path behind one seam;
- voice lifecycle/VAD/interrupt where it belongs.

For the **local-first** target, the `VoiceBackend` composes the existing
`SpeechTranscribing` / `SpeechSynthesizing` adapters and bridges the recognized
turn into an `InferenceBackend` call, streaming the reply back through TTS — i.e.
voice *wraps* inference, it is not a kind of inference. This keeps `ManifoldVoice`
able to grow an `InferenceService`/`InferenceBackend` edge only for the agent
loop, while the dictation accessory keeps its current UI-only dependency.

## v0.1 milestone scope

**In:**

- `VoiceBackend` protocol (session lifecycle + duplex event stream + interrupt).
- One local-first implementation composing today's Apple STT/TTS adapters with a
  text `InferenceBackend` (push-to-talk turn-taking is acceptable for v0.1).
- A minimal VAD or explicit turn signal to close a user turn without a manual
  stop tap.
- A thin `VoiceAgentController` analogous to `VoiceConversationController`,
  plus reuse of the existing accessory UI.
- DocC page + unit tests with mock STT/TTS/inference (no live mic in CI).

**Explicitly out (v0.1):**

- OpenAI Realtime / `gpt-realtime` WebSocket backend (design the seam now,
  implement later).
- SIP / telephony.
- True barge-in / overlapping full-duplex speech-to-speech (push-to-talk first).
- Anthropic voice.
- Multilingual / custom-voice / emotion control.
- Server-side (ManifoldServer) voice endpoints.

## Outcome — recommendation

**(b) Park with documented rationale.** Repo hygiene discourages opening
follow-up / phased issues (CLAUDE.md: "Don't open issues for follow-ups,
phases… Default to no"). The decisions worth preserving — local-first Apple path
first, OpenAI Realtime as the cloud option, a *separate* `VoiceBackend` protocol,
and the v0.1 scope above — are captured here.

Recommend issue **#1415 be labelled `parking-lot`** and left as the durable
pointer to this note. Promote to concrete implementation issues only when a
consuming product (e.g. a voice-mode app surface) creates real demand; at that
point this note is the ready-made v0.1 brief.

*No code was changed by this note — Markdown only.*
