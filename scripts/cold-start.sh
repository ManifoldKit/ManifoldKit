#!/usr/bin/env bash
# scripts/cold-start.sh
#
# Parametric core for the cold-start conformance / import gates — tiers 1-3
# (public consumer surface, ManifoldBootstrap+ChatViewModel orchestration,
# ChatView composition) plus the specialised standalone-product gates
# (ManifoldMCP, ManifoldVoice, ManifoldUIModelManagement). Each one scaffolds
# a fresh SwiftPM consumer in a tmpdir, links ManifoldKit by local path,
# builds, and runs an executable target that proves some slice of the public
# surface works from *outside* the monorepo.
#
# Usage:
#   scripts/cold-start.sh --tier 1|2|3
#   scripts/cold-start.sh --module mcp|voice|uimodelmanagement
#
# The old per-gate entry points are now thin wrappers around this file, kept
# so CI workflows (ci.yml, nightly-slow-tests.yml) and the ci.yml /
# ci-required-test-shim.yml paths-filters do not need to change:
#   scripts/cold-start-conformance.sh                  -> --tier 1
#   scripts/cold-start-tier2-bootstrap.sh               -> --tier 2
#   scripts/cold-start-tier3-chatview.sh                 -> --tier 3
#   scripts/cold-start-specialised-mcp.sh                -> --module mcp
#   scripts/cold-start-specialised-voice.sh              -> --module voice
#   scripts/cold-start-specialised-uimodelmanagement.sh  -> --module uimodelmanagement
#
# See scripts/README.md for the full script inventory + invocation contexts.
#
# Tier 4 (the README "human path" gate) is NOT part of this dispatcher — its
# logic (Markdown parsing, no `swift run`, an optional persistent build
# cache) is structurally different from tiers 1-3. It lives in
# scripts/cold-start-human.sh and reuses only the build helper below.
#
# Bash 3.2 compatible (CI runners) — no `declare -A`, no `mapfile`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=_lib/consumer-scaffold.sh
source "$REPO_ROOT/scripts/_lib/consumer-scaffold.sh"

usage() {
    cat <<'EOF'
Usage: cold-start.sh --tier <1|2|3>
       cold-start.sh --module <mcp|voice|uimodelmanagement>
EOF
}

MODE=""
SELECTOR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            MODE="tier"
            SELECTOR="${2:-}"
            shift 2
            ;;
        --module)
            MODE="module"
            SELECTOR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$MODE" || -z "$SELECTOR" ]]; then
    echo "Missing --tier or --module (with a value)." >&2
    usage >&2
    exit 64
fi

# ── Tier 1: public consumer surface ─────────────────────────────────────────
#
# Exercises Package.swift wiring, the public registration / load / generate
# API, and GenerationStream consumption from the outside in. A downstream
# consumer would normally register Foundation / cloud (or companion-package
# MLX / Llama) backends; the fake backend here keeps the gate free of
# external dependencies (no model files, no OS availability).
write_source_tier1() {
    cat > "Sources/$TARGET_NAME/main.swift" <<'SWIFT'
import ManifoldKit
import Foundation

// MARK: - Inline fake backend
//
// A real downstream consumer would register Foundation / cloud (or the
// companion-package MLX / Llama) backends. For the
// conformance test we want zero external dependencies (no model files, no OS
// availability) so we roll a minimal fake here. This is deliberately the
// *consumer-facing* shape — anything required to conform from outside the
// ManifoldKit monorepo must be public on `InferenceBackend`.

final class FakeBackend: InferenceBackend, @unchecked Sendable {
    nonisolated(unsafe) var isModelLoaded = false
    nonisolated(unsafe) var isGenerating = false

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        supportsSystemPrompt: true,
        memoryStrategy: .external,   // skip the resident-memory plan math
        maxOutputTokens: 64,
        supportsStreaming: true
    )

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            for chunk in ["pong-", "from-", "fake"] {
                continuation.yield(.token(chunk))
            }
            continuation.finish()
        }
        isGenerating = false
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}

// MARK: - Cold-start round trip

@MainActor
func run() async throws -> Int32 {
    let service = InferenceService()
    service.declareSupport(for: .foundation)
    service.registerBackendFactory { type in
        type == .foundation ? FakeBackend() : nil
    }

    // ModelInfo.builtInFoundation is the canonical public entry for Foundation
    // models; we reuse it here to exercise the same code path real consumers
    // would hit, with our fake backend stepping in for Apple's.
    try await service.loadModel(
        from: .builtInFoundation,
        plan: .systemManaged(requestedContextSize: 512)
    )

    let stream = try service.generate(
        messages: [(role: "user", content: "ping")]
    )

    var collected = ""
    for try await event in stream.events {
        if case .token(let chunk) = event {
            collected += chunk
        }
    }

    if collected.isEmpty {
        FileHandle.standardError.write(Data("FAIL: empty reply\n".utf8))
        return 2
    }

    print("OK reply=\(collected.count)chars text=\(collected)")
    return 0
}

let exitCode = try await run()
exit(exitCode)
SWIFT
}

# ── Tier 2: ManifoldBootstrap -> ChatViewModel orchestration ────────────────
#
# Covers the high-level orchestration surface real chat apps use:
# ManifoldBootstrap builds the SwiftData container, persistence provider,
# conversation runtime, endpoint store, and inference service in one shot;
# ChatViewModel is then constructed against that bootstrap and driven through
# one user -> assistant turn via vm.inputText + await vm.sendMessage(). Uses
# an explicit makeModelContainer: override pointing at a tmp URL — two
# bootstraps in the same process collide on the default `default.store` path
# under Application Support.
write_source_tier2() {
    cat > "Sources/$TARGET_NAME/main.swift" <<SWIFT
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldUI
import Foundation
import SwiftData

// MARK: - Inline fake backend
//
// Same shape as tier 1: a downstream consumer would normally register
// Foundation / cloud (or companion-package MLX / Llama) backends, but we
// want zero external dependencies in a conformance run. The fake registers under \`.foundation\` and stops in for
// Apple's built-in model so we exercise the same load → generate path real
// chat apps walk.

final class FakeBackend: InferenceBackend, @unchecked Sendable {
    nonisolated(unsafe) var isModelLoaded = false
    nonisolated(unsafe) var isGenerating = false

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        supportsSystemPrompt: true,
        memoryStrategy: .external,
        maxOutputTokens: 64,
        supportsStreaming: true
    )

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            for chunk in ["pong-", "from-", "tier2"] {
                continuation.yield(.token(chunk))
            }
            continuation.finish()
        }
        isGenerating = false
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}

// MARK: - Cold-start round trip (tier 2)

@MainActor
func run() async throws -> Int32 {
    // Per-test SwiftData store. \`ManifoldBootstrap\`'s default
    // \`makeModelContainer:\` calls \`ModelContainerFactory.makeContainer()\`,
    // which writes \`default.store\` under Application Support. Two
    // bootstraps in the same process collide there, so every non-trivial
    // test (and this conformance runner) must override.
    let storeURL = URL(fileURLWithPath: "$STORE_DIR/cold-start-tier2.store")
    let storeConfig = ModelConfiguration(url: storeURL)

    let configuration = ManifoldConfiguration(
        appName: "ColdStartTier2",
        bundleIdentifier: "com.manifoldkit.coldstart.tier2"
    )

    let bootstrap = try ManifoldBootstrap(
        configuration: configuration,
        makeModelContainer: {
            try ModelContainerFactory.makeContainer(configurations: [storeConfig])
        }
    )

    // Register the fake under .foundation so ModelInfo.builtInFoundation
    // routes to it. declareSupport must come before the load — the
    // lifecycle coordinator gates registration on declared model types.
    bootstrap.inferenceService.declareSupport(for: .foundation)
    bootstrap.inferenceService.registerBackendFactory { type in
        type == .foundation ? FakeBackend() : nil
    }

    try await bootstrap.inferenceService.loadModel(
        from: .builtInFoundation,
        plan: .systemManaged(requestedContextSize: 512)
    )

    // Seed a session in SwiftData so the runtime's user-message insert has
    // a parent row. \`ChatViewModel.sendMessage()\` requires
    // \`activeSession\` to be set — we bypass the SessionManagerViewModel
    // path here because tier 2 is about ChatViewModel, not session list
    // orchestration (that's what makes tier 2 distinct from a real app
    // boot, which would go through SessionManagerViewModel.createSession).
    let sessionRecord = ChatSession(title: "Tier 2 cold-start")
    try await bootstrap.persistence.insertSession(sessionRecord)

    // Construct ChatViewModel against the bootstrap's services. Passing
    // \`bootstrap.conversationRuntime\` is load-bearing: without it the view
    // model creates a default \`InMemoryMessageStore\`-backed runtime, which
    // would persist the user/assistant messages to a different store than
    // \`bootstrap.persistence\`. \`ownsDefaultRuntime\` is then \`false\`, so
    // \`configure(persistence:)\` will not silently replace the runtime —
    // exactly what we want.
    let vm = ChatViewModel(
        inferenceService: bootstrap.inferenceService,
        conversationRuntime: bootstrap.conversationRuntime
    )
    vm.configure(bootstrap: bootstrap)

    vm.activeSession = sessionRecord

    // Drive one turn through the ambient \`inputText\` + \`sendMessage()\`
    // pattern. This is the exact shape ChatInputBar.swift uses, so a
    // regression here would surface in every host app's compose bar.
    vm.inputText = "ping"
    await vm.sendMessage()

    guard let last = vm.messages.last else {
        FileHandle.standardError.write(Data("FAIL: no messages after sendMessage()\n".utf8))
        return 2
    }

    guard last.role == .assistant else {
        let roleString = String(describing: last.role)
        FileHandle.standardError.write(Data("FAIL: last message role=\(roleString), expected assistant\n".utf8))
        return 3
    }

    let text = last.content
    if text.isEmpty {
        FileHandle.standardError.write(Data("FAIL: empty assistant content\n".utf8))
        return 4
    }

    print("OK messages=\(vm.messages.count) reply=\(text.count)chars text=\(text)")
    return 0
}

let exitCode = try await run()
exit(exitCode)
SWIFT
}

# ── Tier 3: ManifoldUI ChatView composition ─────────────────────────────────
#
# Covers the first SwiftUI screen a real app writes around ManifoldKit: a
# fresh consumer imports the public products, creates @Observable view models
# with @State, passes them through .environment(_:), and constructs ChatView
# with a @ViewBuilder apiConfiguration: closure. Catches the two UI
# cold-start mistakes that don't appear in lower tiers: treating the view
# models as Combine ObservableObjects, and forgetting the ChatView
# API-configuration builder shape.
write_source_tier3() {
    cat > "Sources/$TARGET_NAME/main.swift" <<SWIFT
import ManifoldKit
import SwiftData
import SwiftUI

// A custom bubble style defined entirely in consumer code — proves the
// MessageBubbleStyle protocol surface (Configuration, makeBody, the per-role
// background hook) is usable from outside the package.
@MainActor
struct ColdStartBrandBubbleStyle: MessageBubbleStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(10)
            .background(
                configuration.role == .user
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(.fill.tertiary),
                in: RoundedRectangle(cornerRadius: 20)
            )
    }
}

@MainActor
struct RootView: View {
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var showModelManagement = false

    let runtime: ManifoldBootstrap

    init(runtime: ManifoldBootstrap) {
        self.runtime = runtime

        let chat = ChatViewModel(
            inferenceService: runtime.inferenceService,
            conversationRuntime: runtime.conversationRuntime
        )
        chat.configure(bootstrap: runtime)
        _chatViewModel = State(initialValue: chat)

        let sessions = SessionManagerViewModel()
        sessions.configure(bootstrap: runtime)
        _sessionManager = State(initialValue: sessions)
    }

    var body: some View {
        NavigationStack {
            ChatView(
                showModelManagement: \$showModelManagement,
                apiConfiguration: {
                    Text("API configuration")
                }
            )
            // Theming seams exercised from outside the package: Layer 1 tokens
            // via .chatTheme(_:), Layer 2 chrome via a consumer-defined
            // MessageBubbleStyle, Layer 3 per-message override with the
            // defaultMessageView() fallback.
            .chatTheme(
                ChatTheme(
                    userBubbleBackground: AnyShapeStyle(Color.indigo),
                    cornerRadius: 20
                )
            )
            .messageBubbleStyle(ColdStartBrandBubbleStyle())
            .chatMessageRenderer { params in
                params.defaultMessageView()
            }
        }
        .environment(chatViewModel)
        .environment(sessionManager)
        .modelContainer(runtime.modelContainer)
    }
}

@MainActor
func run() throws -> Int32 {
    let storeURL = URL(fileURLWithPath: "$STORE_DIR/cold-start-tier3.store")
    let storeConfig = ModelConfiguration(url: storeURL)

    let runtime = try ManifoldBootstrap(
        configuration: ManifoldConfiguration(
            appName: "ColdStartTier3",
            bundleIdentifier: "com.manifoldkit.coldstart.tier3"
        ),
        makeModelContainer: {
            try ModelContainerFactory.makeContainer(configurations: [storeConfig])
        }
    )

    let root = RootView(runtime: runtime)
    _ = root.body
    print("OK ChatView composed with @State/@Environment Observation, apiConfiguration builder, .chatTheme/.messageBubbleStyle/.chatMessageRenderer seams")
    return 0
}

let exitCode = try await MainActor.run {
    try run()
}
exit(exitCode)
SWIFT
}

# ── Module: ManifoldMCP ──────────────────────────────────────────────────────
#
# Proves that a fresh downstream consumer can add ManifoldMCP as a standalone
# product dependency and reach MCPServerDescriptor, MCPTransportKind, and
# MCPToolSource without importing the full ManifoldKit umbrella. Does not
# exercise MCPClient itself (requires a live server + network) — that is
# ManifoldMCPE2ESmokeTests' job (nightly-slow-tests.yml).
write_source_mcp() {
    cat > "Sources/$TARGET_NAME/main.swift" <<'SWIFT'
import ManifoldMCP
import Foundation

// Verify the primary entry-point types are reachable and can be constructed.
// A consumer building an MCP-enabled chat app would create one of these per
// registered server, store them in a list, and pass them to
// `InferenceService.addToolSource(_:)`.

let serverURL = URL(string: "https://mcp.example.com/sse")!

let descriptor = MCPServerDescriptor(
    displayName: "Example MCP Server",
    transport: .streamableHTTP(endpoint: serverURL, headers: [:]),
    dataDisclosure: "This server receives user messages."
)

// Check that the descriptor round-trips through its Codable conformance.
// A packaging mistake that drops the Codable conformance would fail here.
let encoded = try JSONEncoder().encode(descriptor)
let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: encoded)

guard decoded.displayName == descriptor.displayName else {
    let msg = "FAIL: Codable round-trip changed displayName: \(decoded.displayName)\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

guard decoded.transport == descriptor.transport else {
    FileHandle.standardError.write(Data("FAIL: Codable round-trip changed transport\n".utf8))
    exit(3)
}

print("OK descriptor=\(descriptor.displayName) transport=streamableHTTP Codable-roundtrip=pass")
SWIFT
}

# ── Module: ManifoldVoice ────────────────────────────────────────────────────
#
# Proves that a fresh downstream consumer can add ManifoldVoice as a
# standalone product dependency and reach VoiceError, VoiceCaptureState,
# VoiceRecoveryAffordance, and the SpeechTranscribing / SpeechSynthesizing
# protocol pair. Does not instantiate VoiceConversationController directly
# (dispatches AVFoundation/Speech setup that needs mic/speech entitlements
# unavailable on headless CI runners) — the type-level surface check
# (protocol conformance + enum exhaustiveness) is the meaningful gate.
write_source_voice() {
    cat > "Sources/$TARGET_NAME/main.swift" <<'SWIFT'
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
}

# ── Module: ManifoldUIModelManagement ───────────────────────────────────────
#
# Proves that a fresh downstream consumer can add ManifoldUIModelManagement
# as a standalone product dependency and reach ModelManagementViewModel,
# ModelImportError, and DocumentLibraryViewModel without importing the full
# ManifoldKit umbrella. Does not exercise network paths (HuggingFace search,
# download manager) — those require API keys and live connectivity; the
# type-level surface check is the meaningful gate here.
write_source_uimodelmanagement() {
    cat > "Sources/$TARGET_NAME/main.swift" <<'SWIFT'
import ManifoldUIModelManagement
import Foundation

// ── ModelManagementViewModel check ────────────────────────────────────────
// Consumers typically initialize this with all-nil/default arguments in
// previews, unit tests, and the model-management sheet. Verify both the
// zero-arg path and the diagnostic `searchQuery` property are accessible.
@MainActor
func run() async -> Int32 {
    let vm = ModelManagementViewModel()

    // Verify a writable property from the public surface is reachable.
    vm.searchQuery = "llama"
    guard vm.searchQuery == "llama" else {
        FileHandle.standardError.write(Data("FAIL: searchQuery round-trip failed\n".utf8))
        return 2
    }

    // ── ModelImportError enum check ───────────────────────────────────────
    // Exhaustive switch verifies no cases were accidentally made internal or
    // had their single case removed.
    func describeImportError(_ e: ModelImportError) -> String {
        switch e {
        case .unsupportedFormat: return "unsupportedFormat"
        }
    }

    let sampleError = ModelImportError.unsupportedFormat
    let description = describeImportError(sampleError)
    guard description == "unsupportedFormat" else {
        let msg = "FAIL: unexpected error description: \(description)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        return 3
    }

    // Verify LocalizedError conformance is public — consumers display this
    // in alert dialogs, so a broken errorDescription would be a silent UX bug.
    guard sampleError.errorDescription != nil else {
        FileHandle.standardError.write(Data("FAIL: ModelImportError.errorDescription is nil\n".utf8))
        return 4
    }

    // ── DocumentLibraryViewModel check ───────────────────────────────────
    // ragService: nil produces a non-functional (preview-mode) instance —
    // the standard shape for unit tests and SwiftUI previews.
    let _ = DocumentLibraryViewModel(ragService: nil)

    print("OK ModelManagementViewModel-init=pass ModelImportError-exhaustive=pass DocumentLibraryViewModel-init=pass")
    return 0
}

let exitCode = await run()
exit(exitCode)
SWIFT
}

# ── Dispatch table ───────────────────────────────────────────────────────────
#
# LABEL / CLOSE_LABEL preserve each original script's exact banner text
# (cosmetic only — CI reads exit codes, not this text, but keeping it
# identical means grepping old CI logs for a phrase still works).

USE_REPO_LOCAL_TMP=0
NEEDS_STORE_DIR=0

case "$MODE:$SELECTOR" in
    tier:1)
        LABEL="Cold-start conformance"
        CLOSE_LABEL="Cold-start conformance"
        WORKDIR_PREFIX="cold-start"
        PACKAGE_NAME="ColdStartConsumer"
        TARGET_NAME="ColdStart"
        DEPS=(ManifoldKit)
        WRITE_SOURCE=write_source_tier1
        ;;
    tier:2)
        LABEL="Cold-start conformance (tier 2 — Bootstrap + ChatViewModel)"
        CLOSE_LABEL="Cold-start conformance (tier 2)"
        WORKDIR_PREFIX="cold-start-tier2"
        PACKAGE_NAME="ColdStartTier2Consumer"
        TARGET_NAME="ColdStartTier2"
        DEPS=(ManifoldInference ManifoldRuntime ManifoldPersistenceSwiftData ManifoldUI)
        WRITE_SOURCE=write_source_tier2
        NEEDS_STORE_DIR=1
        ;;
    tier:3)
        LABEL="Cold-start conformance (tier 3 - ChatView composition)"
        CLOSE_LABEL="Cold-start conformance (tier 3)"
        WORKDIR_PREFIX="cold-start-tier3"
        PACKAGE_NAME="ColdStartTier3Consumer"
        TARGET_NAME="ColdStartTier3"
        DEPS=(ManifoldKit)
        WRITE_SOURCE=write_source_tier3
        USE_REPO_LOCAL_TMP=1
        NEEDS_STORE_DIR=1
        ;;
    module:mcp)
        LABEL="Cold-start import gate (ManifoldMCP)"
        CLOSE_LABEL="Cold-start import gate (ManifoldMCP)"
        WORKDIR_PREFIX="cold-start-mcp"
        PACKAGE_NAME="ColdStartMCPConsumer"
        TARGET_NAME="ColdStartMCP"
        DEPS=(ManifoldMCP)
        WRITE_SOURCE=write_source_mcp
        ;;
    module:voice)
        LABEL="Cold-start import gate (ManifoldVoice)"
        CLOSE_LABEL="Cold-start import gate (ManifoldVoice)"
        WORKDIR_PREFIX="cold-start-voice"
        PACKAGE_NAME="ColdStartVoiceConsumer"
        TARGET_NAME="ColdStartVoice"
        DEPS=(ManifoldVoice)
        WRITE_SOURCE=write_source_voice
        ;;
    module:uimodelmanagement)
        LABEL="Cold-start import gate (ManifoldUIModelManagement)"
        CLOSE_LABEL="Cold-start import gate (ManifoldUIModelManagement)"
        WORKDIR_PREFIX="cold-start-uimm"
        PACKAGE_NAME="ColdStartUIMMConsumer"
        TARGET_NAME="ColdStartUIModelManagement"
        DEPS=(ManifoldUIModelManagement)
        WRITE_SOURCE=write_source_uimodelmanagement
        ;;
    *)
        echo "Unknown selector: --$MODE $SELECTOR" >&2
        usage >&2
        exit 64
        ;;
esac

echo "==> $LABEL"
echo "    ManifoldKit:  $REPO_ROOT"

if [[ "$USE_REPO_LOCAL_TMP" == "1" ]]; then
    cs_make_workdir "$WORKDIR_PREFIX" "$REPO_ROOT"
else
    cs_make_workdir "$WORKDIR_PREFIX"
fi
echo "    work:         $WORK"

cd "$WORK"

cs_write_manifest Package.swift "$PACKAGE_NAME" "$REPO_ROOT" executable "$TARGET_NAME" "${DEPS[@]}"

mkdir -p "Sources/$TARGET_NAME"
if [[ "$NEEDS_STORE_DIR" == "1" ]]; then
    STORE_DIR="$WORK/swiftdata"
    mkdir -p "$STORE_DIR"
fi

"$WRITE_SOURCE"

cs_swift_build .
cs_swift_run . "$TARGET_NAME"

echo "==> $CLOSE_LABEL: OK"
