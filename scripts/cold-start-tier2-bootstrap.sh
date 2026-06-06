#!/usr/bin/env bash
# Cold-start conformance — tier 2: Bootstrap + ChatViewModel orchestration path.
#
# Tier 1 (`scripts/cold-start-conformance.sh`) covers the lowest-level surface:
# `ManifoldInference` only, a fake backend, and raw
# `service.generate(messages:)`. It catches breaks in `Package.swift` link
# shape, public registration, the load API, and `GenerationStream`
# consumption.
#
# Tier 2 covers the *high-level orchestration* surface that real chat apps
# use: `ManifoldBootstrap` builds the SwiftData container, persistence
# provider, conversation runtime, endpoint store, and inference service in
# one shot; `ChatViewModel` is then constructed against that bootstrap and
# driven through one user → assistant turn via `vm.inputText` and
# `await vm.sendMessage()`. This is the path that recent agent cold-start
# audits found buggiest:
#
#   - `ManifoldBootstrap` → `ChatViewModel` link shape (ManifoldInference,
#     ManifoldRuntime, ManifoldPersistenceSwiftData, ManifoldUI products
#     must all be reachable from a single downstream consumer).
#   - `ChatViewModel.configure(bootstrap:)` ergonomics — wires persistence
#     and endpoint stores from the bootstrap in one call.
#   - The ambient `vm.inputText = "..."; await vm.sendMessage()` pattern
#     that all production hosts use, including the fact that `sendMessage`
#     consumes `inputText` rather than taking it as an argument.
#   - The `ManifoldBootstrap` default `makeModelContainer:` path resolves
#     to `ModelContainerFactory.makeContainer()`, which in turn writes a
#     `default.store` SQLite file under `Application Support`. Two
#     bootstraps in the same process collide on that path — every
#     non-trivial test must pass an explicit `makeModelContainer:` closure
#     pointing at a tmp URL, even though "tier 2 + isolation" sounds
#     redundant. We do that here both to keep the cold-start runner
#     hermetic and to surface this footgun in the conformance script
#     itself: a downstream consumer that copies this scaffold will see
#     the explicit override and learn the convention before they trip
#     over the collision.
#
# Like tier 1, this rolls a minimal fake `InferenceBackend` inline because
# `ManifoldTestSupport` is intentionally not a public product (the kit's
# `MockInferenceBackend` lives inside that target). The fake registers
# under `.foundation` so the existing `ModelInfo.builtInFoundation` entry
# point exercises the same code path real consumers hit.
#
# Runs in CI on every PR. ~30s on a warm cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t manifoldkit-cold-start-tier2.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start conformance (tier 2 — Bootstrap + ChatViewModel)"
echo "    ManifoldKit:  $REPO_ROOT"
echo "    work:         $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
#
# tools-version 6.2 matches tier 1 (the platforms floor pin to v15 keeps the
# consumer buildable on every macOS ManifoldKit supports). Tier 2 needs four
# products linked in concert:
#
#   - ManifoldInference            — InferenceService, InferenceBackend, BackendCapabilities, ModelLoadPlan, ModelInfo
#   - ManifoldRuntime              — SendInput, ConversationRuntime (transitively via ManifoldPersistenceSwiftData)
#   - ManifoldPersistenceSwiftData — ManifoldBootstrap, ModelContainerFactory, SwiftDataPersistenceProvider
#   - ManifoldUI                   — ChatViewModel, ChatViewModel.configure(bootstrap:)
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartTier2Consumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStartTier2", targets: ["ColdStartTier2"]),
    ],
    dependencies: [
        // Pin the dependency identity to "ManifoldKit" instead of letting
        // SwiftPM derive it from the last path component. CI checks out to
        // a directory named ManifoldKit so the inferred identity matches,
        // but local runs from a git worktree (\`.claude/worktrees/agent-*\`)
        // would otherwise resolve the identity to the worktree dir name
        // and fail \`.product(package: "ManifoldKit")\`.
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "ColdStartTier2",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldRuntime", package: "ManifoldKit"),
                .product(name: "ManifoldPersistenceSwiftData", package: "ManifoldKit"),
                .product(name: "ManifoldUI", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStartTier2"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
mkdir -p Sources/ColdStartTier2
STORE_DIR="$WORK/swiftdata"
mkdir -p "$STORE_DIR"

cat > Sources/ColdStartTier2/main.swift <<SWIFT
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldUI
import Foundation
import SwiftData

// MARK: - Inline fake backend
//
// Same shape as tier 1: a downstream consumer would normally register MLX /
// Llama / Foundation backends, but we want zero external dependencies in a
// conformance run. The fake registers under \`.foundation\` and stops in for
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
    let sessionRecord = ChatSessionRecord(title: "Tier 2 cold-start")
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

# 3. Build.
echo "==> swift build"
swift build --package-path . 2>&1 | tail -40

# 4. Run.
echo "==> swift run"
swift run --package-path . ColdStartTier2
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start tier-2 consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start conformance (tier 2): OK"
