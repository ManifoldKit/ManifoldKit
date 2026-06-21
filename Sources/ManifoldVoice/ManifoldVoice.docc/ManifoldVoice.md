# ``ManifoldVoice``

Speech-to-text and text-to-speech for Swift apps.

## Overview

`ManifoldVoice` is a thin, testable wrapper over Apple's `Speech` and `AVFoundation`
frameworks. It exposes a small set of protocols (``SpeechTranscribing``,
``SpeechSynthesizing``) and a default `@MainActor`
``VoiceConversationController`` that coordinates microphone permission,
streaming transcripts, and TTS playback.

**The module is not chat-specific.** Despite shipping a `VoiceComposerAccessory`
view for ManifoldKit's chat composer, the underlying controller and services
have no dependency on `ChatViewModel`, `MessageStore`, or any other chat type.
You can use ``VoiceConversationController`` to drive an image-generation prompt
field, a CLI dictation tool, a hands-free toggle in a non-chat SwiftUI app, or
any other surface that needs streaming speech recognition.

Two ways to consume it:

- **Standalone STT/TTS** — instantiate ``VoiceConversationController`` directly,
  observe ``VoiceConversationController/liveTranscript`` and
  ``VoiceConversationController/captureState``, route the committed transcript
  to whatever your app needs. See <doc:StandaloneSpeechRecognition>.
- **Chat composer accessory** — drop `VoiceComposerAccessory` into a
  `ChatView`'s composer slot to add a push-to-talk mic button with live
  transcript preview. See the v0.11.x CHANGELOG entries and the
  `Example/Advanced` reference app.

## Permissions

Any host that links `ManifoldVoice` and starts recording must declare both
keys in its `Info.plist`:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

``VoiceConversationController/startRecording()`` returns a `.failed` state
with a localized message when either authorization is denied.

## Platform notes

- The iOS Simulator does not provide a microphone input — capture fails with
  ``VoiceError/simulatorUnsupported``. Gate UI accordingly or test on device.
- ``AppleSpeechTranscriber`` uses `SFSpeechRecognizer` (network or on-device
  depending on locale support); ``AppleSpeechSynthesizer`` uses `AVSpeechSynthesizer`.
- Inject your own ``SpeechTranscribing`` / ``SpeechSynthesizing`` implementations
  in tests to avoid touching the audio session.

## When to use this module

Import `ManifoldVoice` directly when:

- You want **streaming STT in any SwiftUI view** — a search bar, image-generation
  prompt field, note-taking surface, or accessibility aid — without building
  a chat session.
- You need **TTS readback** of model output or any other text, with start/stop
  control and an `isSpeaking` observable property to drive UI.
- You are building an accessibility-first UI and need `VoiceCaptureState`
  changes to drive button labels and progress indicators.
- You want to replace `SFSpeechRecognizer` with a different STT engine (e.g. a
  local Whisper model) without changing the rest of your UI — inject your own
  ``SpeechTranscribing`` conformer.

## When not to use this module

- **You only need text input.** If push-to-talk is an optional enhancement, you
  can ship the text path first and add `ManifoldVoice` later. The module adds
  `Speech` and `AVFoundation` link-time cost even when the user never taps the
  mic button.
- **You need server-side or Whisper-based STT.** The shipped ``AppleSpeechTranscriber``
  uses `SFSpeechRecognizer` — inject a custom ``SpeechTranscribing`` conformer
  instead of using this module as-is.
- **You are testing on a simulator.** Recording always fails with
  ``VoiceError/simulatorUnsupported``. Inject a ``SpeechTranscribing`` mock
  that yields scripted updates instead of touching the audio session.

## Beyond chat

``VoiceConversationController`` has no dependency on chat types. Common
non-chat patterns:

- **Dictation field** — observe `liveTranscript` to mirror the in-flight
  transcript into a `TextField`; commit `stopRecording()` to the field's binding.
  See <doc:StandaloneSpeechRecognition> for a full worked example.
- **Image-generation prompt** — drive `startRecording()` / `stopRecording()`
  from a mic button next to the diffusion prompt field; feed the committed
  transcript directly to `ImageGenerationService`.
- **Accessibility readback** — call `speak(_:)` on ``AppleSpeechSynthesizer``
  (or any ``SpeechSynthesizing`` conformer) to read assistant replies aloud in
  a hands-free context. The controller tracks `isSpeaking` so a stop button
  can be shown only while TTS is active.

## The 3–5 most-used types

### `VoiceConversationController` — the top-level coordinator

``VoiceConversationController`` is a `@MainActor @Observable` class that
coordinates the full voice lifecycle. Zero-argument init uses Apple's built-in
speech recognition and synthesis:

```swift,no-build
import SwiftUI
import ManifoldVoice

@MainActor
struct PromptBar: View {
    @State private var voice = VoiceConversationController()
    @Binding var prompt: String

    var body: some View {
        HStack {
            TextField("Describe an image", text: $prompt)
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(voice.isRecording ? .red : .secondary)
            }
        }
        // Mirror the live transcript into the field while recording.
        .onChange(of: voice.liveTranscript) { _, text in
            if voice.isRecording { prompt = text }
        }
    }

    private func toggleRecording() async {
        if voice.isRecording {
            if let committed = await voice.stopRecording() {
                prompt = committed   // replace live preview with final result
            }
        } else {
            await voice.startRecording()
        }
    }
}
```

### `VoiceCaptureState` — drive your UI

``VoiceCaptureState`` is an `Equatable` enum that tracks the controller's
lifecycle. Observe it to show permission-request spinners, recording indicators,
and error messages:

```swift,no-build
import ManifoldVoice

switch voice.captureState {
case .idle:
    micButton.isEnabled = true
case .requestingPermission:
    micButton.isEnabled = false
    statusLabel.text = "Requesting access…"
case .recording:
    micButton.tintColor = .systemRed
    statusLabel.text = voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript
case .processing:
    micButton.isEnabled = false
    statusLabel.text = "Finishing transcript…"
case .failed(let message):
    micButton.isEnabled = true
    statusLabel.text = message
}
```

``VoiceConversationController/statusText`` provides a pre-computed human-readable
string that covers the same cases, including the `isSpeaking` TTS state.

### `SpeechTranscribing` — inject a custom STT backend

Conform to ``SpeechTranscribing`` to swap out `SFSpeechRecognizer` — for
example to route audio through a local Whisper model or a server-side STT
service. The protocol is four `@MainActor` methods:

```swift,no-build
import ManifoldVoice

final class WhisperTranscriber: SpeechTranscribing {
    @MainActor
    func requestAuthorization() async -> VoiceAuthorizationStatus { .authorized }

    @MainActor
    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        // Start your audio pipeline; call onUpdate as partials arrive.
        onUpdate(SpeechTranscriptionUpdate(text: "partial…", isFinal: false))
    }

    @MainActor
    func stopTranscribing() async throws -> String? {
        // Flush the final result; return nil to let the controller use liveTranscript.
        return nil
    }

    @MainActor func cancelTranscribing() { /* stop audio pipeline */ }
}

// Inject at construction time.
let controller = VoiceConversationController(transcriber: WhisperTranscriber())
```

In unit tests, inject a scripted conformer that feeds canned ``SpeechTranscriptionUpdate``
values synchronously — no audio session needed.

## Topics

### Standalone usage

- <doc:StandaloneSpeechRecognition>

### Controller

- ``VoiceConversationController``
- ``VoiceCaptureState``

### Protocols

- ``SpeechTranscribing``
- ``SpeechSynthesizing``

### Value types

- ``SpeechTranscriptionUpdate``
- ``VoiceAuthorizationStatus``
- ``VoiceError``

### Apple-backed implementations

- ``AppleSpeechTranscriber``
- ``AppleSpeechSynthesizer``
