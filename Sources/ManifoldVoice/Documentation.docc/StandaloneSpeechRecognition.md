# Standalone speech recognition

Use `ManifoldVoice` without a chat surface.

## Overview

``VoiceConversationController`` is a standalone `@Observable` `@MainActor`
coordinator. It owns a ``SpeechTranscribing`` and a ``SpeechSynthesizing``,
exposes streaming transcripts through ``VoiceConversationController/liveTranscript``,
and returns a committed transcript from
``VoiceConversationController/stopRecording()``. None of its public API
mentions chat sessions, messages, or composers.

The snippet below dictates into an arbitrary `String` binding — drop it
behind a mic button in any SwiftUI view (image-gen prompt, search bar,
note-taking field, etc.).

```swift
import SwiftUI
import ManifoldVoice

@MainActor
struct DictationField: View {
    @State private var voice = VoiceConversationController()
    @State private var prompt = ""

    var body: some View {
        HStack {
            TextField("Prompt", text: $prompt)
            Button {
                Task { await toggle() }
            } label: {
                Image(systemName: voice.isRecording ? "mic.fill" : "mic")
            }
        }
        .onChange(of: voice.liveTranscript) { _, newValue in
            // Mirror the streaming transcript into the field while recording.
            if voice.isRecording { prompt = newValue }
        }
        .alert(
            "Voice error",
            isPresented: .constant(voice.errorMessage != nil),
            actions: { Button("OK") { voice.cancelRecording() } },
            message: { Text(voice.errorMessage ?? "") }
        )
    }

    private func toggle() async {
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

## Custom transcriber

Inject your own ``SpeechTranscribing`` to replace `SFSpeechRecognizer` (e.g.
to integrate a local Whisper backend or a server-side STT service):

```swift
import ManifoldVoice

final class WhisperTranscriber: SpeechTranscribing {
    @MainActor func requestAuthorization() async -> VoiceAuthorizationStatus { .authorized }
    @MainActor func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        // ... pipe partials to `onUpdate(.init(text:isFinal:))` ...
    }
    @MainActor func stopTranscribing() async throws -> String? { nil }
    @MainActor func cancelTranscribing() {}
}

let controller = VoiceConversationController(transcriber: WhisperTranscriber())
```

## Permissions

Host apps must declare:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

See <doc:ManifoldVoice> for the broader module overview and platform notes.
