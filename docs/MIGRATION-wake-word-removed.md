# Migration: `ManifoldVoice` wake-word detection removed

**Audience:** consumer
**Status:** living

**This is a breaking change.** `ManifoldVoice` no longer ships wake-word
phrase detection. The subsystem was removed in **v0.59.0** (PR
[#2007](https://github.com/ManifoldKit/ManifoldKit/pull/2007), 2026-06-21);
there is no replacement in core.

This note is written retroactively. Principle 9 requires a migration doc for
every retired API, and this removal shipped without one — `docs/QUICKSTART-VOICE.md`
kept an entire "Wake words" section stating *"`ManifoldVoice` ships
`AppleWakeWordDetector`"* for five weeks after the type ceased to exist. The
`DocClaimsAuditTest` symbol tripwire now makes that class of drift a per-PR
failure rather than something a reader discovers.

## What was removed

| Symbol | Kind | Was in |
|---|---|---|
| `AppleWakeWordDetector` | `public final class` | `Sources/ManifoldVoice/Services/AppleWakeWordDetector.swift` (deleted) |
| `WakeWordDetector` | `public protocol` | `Sources/ManifoldVoice/VoiceTypes.swift` |
| `WakeWordDetection` | `public struct` | `Sources/ManifoldVoice/VoiceTypes.swift` |
| `WakeWordToast` | `public struct` (SwiftUI `View`) | `Sources/ManifoldVoice/Views/WakeWordToast.swift` (deleted) |
| `VoiceConversationController.recentWakeWordDetection` | `public private(set) var` | `VoiceConversationController.swift` |
| `VoiceConversationController.init(wakeWordDetector:)` | initialiser parameter | `VoiceConversationController.swift` |

The rest of `ManifoldVoice` is unaffected: `VoiceConversationController`,
`SpeechTranscribing` / `AppleSpeechTranscriber`, `SpeechSynthesizing` /
`AppleSpeechSynthesizer`, `VoiceActivityDetector` /
`EnergyVoiceActivityDetector`, `LiveTranscriptionView`, `VoiceInputButton`,
and `VoiceComposerAccessory` all remain.

## Symptoms

```
cannot find 'AppleWakeWordDetector' in scope
cannot find type 'WakeWordDetector' in scope
value of type 'VoiceConversationController' has no member 'recentWakeWordDetection'
extra argument 'wakeWordDetector' in call
```

## What to do instead

Wake-word matching was a thin consumer of the transcript stream — it inspected
each `SpeechTranscriptionUpdate` and reported a hit. Host that logic yourself:

```swift,no-build:illustrates a host-side pattern, not a ManifoldKit API — the phrase-matching type is the reader's to write
import ManifoldVoice

@MainActor
final class PhraseTrigger {
    private let phrases: [String]
    private(set) var recentMatch: String?

    init(phrases: [String]) {
        // Normalise once; transcripts arrive lowercased inconsistently across
        // locales, so compare case-insensitively.
        self.phrases = phrases.map { $0.lowercased() }
    }

    /// Call from your `SpeechTranscribing.startTranscribing(onUpdate:)` handler.
    func ingest(_ update: SpeechTranscriptionUpdate) -> String? {
        let haystack = update.text.lowercased()
        guard let hit = phrases.first(where: haystack.contains) else { return nil }
        recentMatch = hit
        return hit
    }
}
```

Wire it into the transcript callback you already own:

```swift,no-build:continuation of the snippet above — depends on the host-defined PhraseTrigger
let trigger = PhraseTrigger(phrases: ["hey assistant", "ok manifold"])

try await transcriber.startTranscribing { update in
    if let phrase = trigger.ingest(update) {
        // Start a turn, show a toast, fire a haptic — host's choice.
        print("matched \(phrase)")
    }
}
```

The removed `AppleWakeWordDetector` also auto-cleared `recentWakeWordDetection`
about two seconds after a match, and `WakeWordToast` rendered it. Both are
presentation concerns: if you want that behaviour, clear `recentMatch` from a
`Task` with a sleep, and render it with your own view.

## Why it was removed

PR #2007 was a UX-hardening pass across server, chat, voice, and model
management. The wake-word path was cut rather than fixed: on-device phrase
matching against a partial transcript stream is unreliable enough (locale
handling, partial-vs-final updates, no acoustic model) that shipping it as a
first-class API implied a robustness it did not have. Pre-1.0 policy is to
delete rather than deprecate, so it was removed outright — see
[API-DESIGN.md](API-DESIGN.md) § public API design policy.
