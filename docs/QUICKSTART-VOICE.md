# ManifoldKit Voice Quickstart

A one-page tutorial for adding speech-to-text and text-to-speech to any Swift
app — chat or not. If you've read the CHANGELOG and concluded that
`ManifoldVoice` is for chat composers only: it isn't. The composer accessory
is one consumer; the underlying ``VoiceConversationController`` is a
chat-agnostic primitive that anything can drive.

> **Platform.** SFSpeechRecognizer + AVFoundation; macOS 15+ / iOS 18+. The
> iOS Simulator has no microphone — recording raises
> `VoiceError.simulatorUnsupported`. Test on device.

---

## 1. Add the `ManifoldVoice` product

No trait required — the former `Voice` trait was retired in v0.48. In your
consumer `Package.swift`:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/ManifoldKit/ManifoldKit.git",
        from: "0.64.0" // x-release-please-version
        // Depending on just the ManifoldVoice product keeps the inference
        // stack out of your app graph — core has no heavy ML deps since v0.48.
    ),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "ManifoldVoice", package: "ManifoldKit"),
        ]
    ),
],
```

`ManifoldVoice` is a sibling product — you import it directly, not through the
`ManifoldKit` umbrella. It has no dependency on `ManifoldRuntime` or any chat type.

> **Info.plist.** Add both keys before recording, or authorization fails:
> - `NSMicrophoneUsageDescription`
> - `NSSpeechRecognitionUsageDescription`
>
> **A bare `swift run` executable can't carry these keys.** SwiftPM rejects a
> bundled `Info.plist` as a resource (`resource 'Info.plist' … forbidden`), and a
> command-line binary has no app bundle to hold usage strings — so microphone /
> speech authorization can never be granted and `VoiceConversationController`
> lands in `.failed(...)`. Voice needs an **Xcode `.app` target** (or an
> `xcodebuild` app bundle) with these keys in its `Info.plist`. A SwiftUI app
> target has one by default; a SwiftPM command-line tool does not — plan for an
> `.app` if voice is in scope.

---

## 2. Standalone dictation — SwiftUI

`VoiceConversationController` is `@Observable` and `@MainActor`. Bind its
``VoiceConversationController/liveTranscript`` straight into whatever field
your app uses — an image-gen prompt, a search bar, a notes field. The
controller does not know or care that ManifoldKit ships a chat UI.

```swift,no-build
import SwiftUI
import ManifoldVoice

@MainActor
struct PromptDictationView: View {
    @State private var voice = VoiceConversationController()
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Describe the image you want…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(
                        voice.isRecording ? "Stop" : "Dictate",
                        systemImage: voice.isRecording ? "stop.circle.fill" : "mic"
                    )
                }
                if let status = voice.statusText {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onChange(of: voice.liveTranscript) { _, newValue in
            // Mirror the streaming partial into the field while recording so the
            // user sees progress; the committed transcript replaces it on stop.
            if voice.isRecording { prompt = newValue }
        }
    }

    private func toggleRecording() async {
        if voice.isRecording {
            if let committed = await voice.stopRecording() {
                prompt = committed
            }
        } else {
            await voice.startRecording()
        }
    }
}
```

That's the whole standalone STT integration. No `ChatViewModel`, no
`MessageStore`, no `ConversationRuntime`.

---

## 3. Standalone TTS

The same controller speaks arbitrary strings — useful for read-aloud features
in any app:

```swift,no-build
let voice = VoiceConversationController()
voice.togglePlayback(for: "Generation complete. Tap to view the result.")

// Later, or on user cancel:
voice.stopSpeaking()
```

``VoiceConversationController/isSpeaking`` reflects playback state for
binding into UI.

---

## 4. Injecting a custom transcriber

The Apple-backed transcriber is the default, but ``SpeechTranscribing`` is
just a protocol — wire in a local Whisper, an HTTP STT endpoint, or a
deterministic test fake:

```swift,no-build
final class FakeTranscriber: SpeechTranscribing {
    @MainActor func requestAuthorization() async -> VoiceAuthorizationStatus { .authorized }
    @MainActor func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        onUpdate(.init(text: "hello world", isFinal: true))
    }
    @MainActor func stopTranscribing() async throws -> String? { "hello world" }
    @MainActor func cancelTranscribing() {}
}

let voice = VoiceConversationController(transcriber: FakeTranscriber())
```

Same shape for ``SpeechSynthesizing`` (TTS) and ``WakeWordDetector``.

---

## 5. Wake words

`ManifoldVoice` ships ``AppleWakeWordDetector`` for on-device phrase matching
against the live transcript stream:

```swift,no-build
let detector = AppleWakeWordDetector(wakeWords: ["hey assistant", "ok manifold"])
let voice = VoiceConversationController(wakeWordDetector: detector)

// Observe voice.recentWakeWordDetection — it appears for ~2s after a match,
// then auto-clears. Plug it into a toast, haptic, or auto-start logic.
```

---

## 6. Using the chat composer accessory (the other path)

If you *are* building on top of ManifoldKit's `ChatView`, the chat-shaped
adapter is `VoiceComposerAccessory` — a SwiftUI view that slots into the
composer accessory seam and drives the same ``VoiceConversationController``.
See the `Example/Advanced` reference app for end-to-end wiring. The
standalone path documented above is the right choice for anything that
isn't a chat surface.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `VoiceError.simulatorUnsupported` | iOS Simulator — no microphone. Test on device. |
| `.failed("Microphone access is required…")` | `NSMicrophoneUsageDescription` missing from `Info.plist`. |
| `.failed("Speech recognition permission…")` | `NSSpeechRecognitionUsageDescription` missing. |
| `VoiceError.unsupportedLocale` | `SFSpeechRecognizer(locale:)` returned nil — pass a supported locale or `.current`. |
| `liveTranscript` stuck empty | Authorization denied silently — check ``VoiceConversationController/errorMessage``. |

---

## Realtime voice: full-duplex, SpeechAnalyzer, VAD, and barge-in

> **Not yet shipped.** Full-duplex conversation with voice activity detection
> (VAD), barge-in interruption, Apple's `SpeechAnalyzer` framework, and
> WhisperKit integration are tracked in
> [#1928](https://github.com/ManifoldKit/ManifoldKit/issues/1928). The current
> `ManifoldVoice` surface is half-duplex only — STT and TTS run in mutually
> exclusive states, not simultaneously. See [plans/archive/voice-surface-scoping.md](plans/archive/voice-surface-scoping.md)
> for the design notes.
