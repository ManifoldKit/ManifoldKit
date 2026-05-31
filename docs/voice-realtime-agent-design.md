# Design note: realtime voice-agent surface

**Status: PARKED (2026-05-31).** Decision captured per #1415; implementation deferred until after Glass Box Foundation (v0.39) lands. Revisit when the runtime-observability train is shipped.

## Decision in one line

ManifoldKit will eventually claim the empty "Swift realtime voice-agent" quadrant via a **dedicated `VoiceBackend` protocol** with **OpenAI Realtime (WebSocket) first** — but not now. The local Apple-speech path already covers the non-realtime need, and the realtime surface is a large new lifecycle that would compete directly with Glass Box for post-v0.38 attention.

## Current state (already shipped — out of scope here)

The local-first path is built and maintained, and is **not** part of the open question:

- Services: `VoiceConversationController`, `AppleSpeechTranscriber`, `AppleSpeechSynthesizer`, `AppleWakeWordDetector`, `VoiceAudioSessionCoordinator`
- UI: `LiveTranscriptionView`, `VoiceInputButton`, `VoiceComposerAccessory`, `WakeWordToast`
- Docs: `QUICKSTART-VOICE.md`, ManifoldVoice DocC

This is half-duplex turn-taking layered on top of the existing text turn loop: STT → `ConversationRuntime` turn → TTS. It is sufficient for "speak a message, hear the reply."

## The gap (what's actually being scoped)

A **realtime/full-duplex voice agent** is a different thing: continuous bidirectional audio, server-side VAD, barge-in (user interrupts mid-response), sub-second latency, and a session that outlives a single turn. As of May 2026 no production-grade Swift SDK fills this; OpenAI/Anthropic/Google all ship it in their primary SDKs.

## Why it needs a separate `VoiceBackend` protocol

The existing `InferenceBackend` is request/response: `generate(prompt:...) -> GenerationStream` — one prompt in, one token stream out, then done. A realtime voice session inverts that:

| Aspect | `InferenceBackend` | realtime voice |
|---|---|---|
| Lifecycle | per-turn | long-lived session |
| Direction | text in → tokens out | duplex audio ↔ audio |
| Interruption | cancel the turn | barge-in mid-utterance |
| Turn boundaries | caller-defined | server VAD detects them |
| Transport | HTTP/SSE or in-process | persistent WebSocket / SIP |

Forcing this onto `InferenceBackend` would distort both. A separate `VoiceBackend` (or `RealtimeVoiceSession`) protocol — owning audio in/out, a `VoiceSessionEvent` stream (`speechStarted`, `transcriptDelta`, `audioDelta`, `bargeIn`, `turnComplete`), and explicit `interrupt()`/`commitAudio()` — is the right seam. It composes with the existing tool-calling/agent surfaces but does not ride the text backend.

## Transport order (when un-parked)

1. **OpenAI Realtime API (WebSocket, `gpt-realtime`)** — first. Most mature, well-documented, immediate value.
2. **Apple on-device** — STT/TTS already shipped; a fully local low-latency loop is a follow-up, not v0.1.
3. **Anthropic voice** — adopt when/if a realtime surface ships.
4. SIP — defer indefinitely; telephony is a niche we don't need to claim early.

## v0.1 milestone sketch (for when work begins)

- `VoiceBackend` protocol + `VoiceSessionEvent` stream in `ManifoldInference` (the shared home, below the family targets)
- `OpenAIRealtimeBackend` in `ManifoldCloud`, behind a `Realtime` (or extended `Voice`) trait
- Mic capture + audio playback coordinator reusing `VoiceAudioSessionCoordinator`
- Barge-in: `interrupt()` cancels playback and commits the user's audio
- Tool calling routed through the existing `SessionToolSource` seam
- One demo card + a golden-trace scenario (rides the Glass Box scenario harness once it exists — another reason to sequence this after v0.40)

## Park rationale

- The differentiating value is real but the surface is large (new protocol, new transport, audio/session lifecycle).
- It competes for the same post-v0.38 attention as the Glass Box train, which is already greenlit and de-risked.
- The realtime scenario would ideally ship *on* the Glass Box scenario-as-contract harness (v0.40), so starting before that exists means rework.

**Un-park trigger:** Glass Box Foundation (v0.39) merged, or a concrete consumer pull for realtime voice — whichever comes first.
