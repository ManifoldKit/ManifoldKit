# ``ManifoldVoice``

Speech-to-text, text-to-speech, and wake-word detection for Swift apps.

## Overview

`ManifoldVoice` is a thin, testable wrapper over Apple's `Speech` and `AVFoundation`
frameworks. It exposes a small set of protocols (``SpeechTranscribing``,
``SpeechSynthesizing``, ``WakeWordDetector``) and a default `@MainActor`
``VoiceConversationController`` that coordinates microphone permission,
streaming transcripts, wake-word detection, and TTS playback.

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

## Topics

### Standalone usage

- <doc:StandaloneSpeechRecognition>

### Controller

- ``VoiceConversationController``
- ``VoiceCaptureState``

### Protocols

- ``SpeechTranscribing``
- ``SpeechSynthesizing``
- ``WakeWordDetector``

### Value types

- ``SpeechTranscriptionUpdate``
- ``WakeWordDetection``
- ``VoiceAuthorizationStatus``
- ``VoiceError``

### Apple-backed implementations

- ``AppleSpeechTranscriber``
- ``AppleSpeechSynthesizer``
- ``AppleWakeWordDetector``
