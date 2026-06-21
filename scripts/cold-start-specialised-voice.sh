#!/usr/bin/env bash
# Cold-start import gate — ManifoldVoice specialised module.
#
# Proves that a fresh downstream consumer can add ManifoldVoice as a standalone
# product dependency and reach its public surface (`VoiceConversationController`,
# `VoiceError`, `VoiceCaptureState`, the `SpeechTranscribing` / `SpeechSynthesizing`
# protocols) without importing the full ManifoldKit umbrella.
#
# Catches: missing public exports, broken product → target wiring in
# Package.swift, accidental removal of public types, and dependency-graph
# changes that drop ManifoldUI (ManifoldVoice's only required dep).
#
# No trait involved — the Voice trait was retired in v0.48 (PR A3);
# ManifoldVoice compiles unconditionally and consumers opt in by adding the
# product dependency, exactly as this gate does.
#
# Does NOT exercise live speech I/O (requires device microphone + synthesis
# engine, unavailable in CI). The gate verifies that the import compiles and
# that the public types are usable from outside the package.
#
# Runs in CI on every PR. ~30s on a warm cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t manifoldkit-cold-start-voice.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start import gate (ManifoldVoice)"
echo "    ManifoldKit:  $REPO_ROOT"
echo "    work:         $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
#
# Depends on ManifoldVoice alone — not the full umbrella — to verify the
# product is independently linkable. tools-version 6.2 matches ManifoldKit.
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartVoiceConsumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStartVoice", targets: ["ColdStartVoice"]),
    ],
    dependencies: [
        // Pin package identity explicitly so worktree directory names do not
        // change the identity seen by .product(package:).
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "ColdStartVoice",
            dependencies: [
                .product(name: "ManifoldVoice", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStartVoice"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
#
# Exercises the public value types and protocol surfaces documented in the
# ManifoldVoice integration guide:
#   1. `VoiceError` — the public error enum consumers catch when
#      speech recognition or microphone access fails.
#   2. `VoiceCaptureState` — the state machine enum; consumers observe this
#      to drive push-to-talk / recording UI.
#   3. `SpeechTranscribing` / `SpeechSynthesizing` — the protocol pair that
#      lets consumers swap in custom transcription/synthesis engines.
#
# Does not instantiate `VoiceConversationController` directly because its
# init requires conforming objects and dispatches AVFoundation/Speech setup
# internally — those calls are safe on device but are not available on
# headless CI runners without mic/speech entitlements. The type-level surface
# check (protocol conformance + enum exhaustiveness) is the meaningful gate.
mkdir -p Sources/ColdStartVoice
cat > Sources/ColdStartVoice/main.swift <<'SWIFT'
import ManifoldVoice
import Foundation

// ── VoiceError enum check ─────────────────────────────────────────────────
// A consumer that catches VoiceError needs every case to be visible. Exhaustive
// switch verifies no cases were accidentally made internal or removed.
func describeError(_ e: VoiceError) -> String {
    switch e {
    case .recognizerUnavailable: return "recognizerUnavailable"
    case .unsupportedLocale: return "unsupportedLocale"
    case .speechRecognitionDenied: return "speechRecognitionDenied"
    case .speechRecognitionNotDetermined: return "speechRecognitionNotDetermined"
    case .speechRecognitionRestricted: return "speechRecognitionRestricted"
    case .microphoneAccessDenied: return "microphoneAccessDenied"
    case .simulatorUnsupported: return "simulatorUnsupported"
    case .setupFailed(let reason): return "setupFailed(\(reason))"
    }
}

// ── VoiceCaptureState enum check ──────────────────────────────────────────
// Consumers drive their recording indicator and transcription overlay from
// this state. Exhaustive switch verifies no states were accidentally hidden.
func describeState(_ s: VoiceCaptureState) -> String {
    switch s {
    case .idle: return "idle"
    case .requestingPermission: return "requestingPermission"
    case .recording: return "recording"
    case .processing: return "processing"
    case .failed(let reason): return "failed(\(reason))"
    }
}

// ── VoiceRecoveryAffordance enum check ────────────────────────────────────
// Views switch on this to pick the right recovery control (Open Settings /
// request again / retry). Exhaustive switch verifies no cases were hidden.
func describeAffordance(_ a: VoiceRecoveryAffordance) -> String {
    switch a {
    case .openSettings: return "openSettings"
    case .requestAgain: return "requestAgain"
    case .retry: return "retry"
    }
}

// ── Protocol conformance check ────────────────────────────────────────────
// Prove that a consumer-defined type can conform to SpeechTranscribing and
// SpeechSynthesizing — the public protocol pair for custom voice engines.
// This verifies the protocol requirements are stable and publicly accessible.
@MainActor
final class NoOpTranscriber: SpeechTranscribing {
    func requestAuthorization() async -> VoiceAuthorizationStatus { .denied }
    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {}
    func stopTranscribing() async throws -> String? { nil }
    func cancelTranscribing() {}
}

@MainActor
final class NoOpSynthesizer: SpeechSynthesizing {
    func speak(_ text: String) async throws {}
    func stopSpeaking() {}
}

// ── Sanity check ─────────────────────────────────────────────────────────
@MainActor
func run() -> Int32 {
    let idleState = describeState(.idle)
    let recordingState = describeState(.recording)

    guard idleState == "idle", recordingState == "recording" else {
        FileHandle.standardError.write(Data("FAIL: unexpected state description\n".utf8))
        return 2
    }

    let _ = NoOpTranscriber()
    let _ = NoOpSynthesizer()

    let settingsAffordance = describeAffordance(.openSettings)
    guard settingsAffordance == "openSettings" else {
        FileHandle.standardError.write(Data("FAIL: unexpected affordance description\n".utf8))
        return 3
    }

    print("OK VoiceError-exhaustive=pass VoiceCaptureState-exhaustive=pass VoiceRecoveryAffordance-exhaustive=pass SpeechTranscribing-conformable=pass SpeechSynthesizing-conformable=pass")
    return 0
}

let exitCode = await MainActor.run { run() }
exit(exitCode)
SWIFT

# 3. Build and run.
# safe.bareRepository override needed when building from a git worktree.
SWIFT_ENV=(
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=safe.bareRepository
    GIT_CONFIG_VALUE_0=all
)

echo "==> swift build"
env "${SWIFT_ENV[@]}" swift build --package-path . 2>&1 | tail -40

echo "==> swift run"
env "${SWIFT_ENV[@]}" swift run --package-path . ColdStartVoice
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start Voice consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start import gate (ManifoldVoice): OK"
