#!/usr/bin/env bash
# Cold-start conformance test.
#
# Scaffolds a fresh SwiftPM consumer in a tmpdir, links ManifoldKit by local
# path, builds against the public consumer surface (ManifoldInference only —
# no internal test-support targets), runs one chat turn through a tiny inline
# fake backend, and asserts the round trip works.
#
# This is the missing test that would have caught most of the friction
# documented in agent cold-start runs (BCK-test-01, BCK-test-02): it exercises
# Package.swift wiring, BCK linking, the public registration / load / generate
# API, and the GenerationStream consumption pattern from the *outside in*.
#
# Runs in CI on every PR. ~30s on a warm cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t bck-cold-start.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start conformance"
echo "    BCK:  $REPO_ROOT"
echo "    work: $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
#
# tools-version 6.2 is required for `.macOS(.v26)`; we pin to v15 (BCK's floor)
# so the test runs on every macOS BCK supports, not just the latest.
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartConsumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStart", targets: ["ColdStart"]),
    ],
    dependencies: [
        // Pin package identity explicitly. SwiftPM derives \`.package(path:)\`
        // identity from the last path component, not the manifest \`name:\`. On
        // a normal checkout the dir is \`ManifoldKit\` so \`.product(... package:
        // "ManifoldKit")\` resolves; in a worktree (e.g. \`agent-<id>\`) it would
        // not. Pinning \`name:\` keeps this script worktree-portable.
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "ColdStart",
            dependencies: [
                // ManifoldKit umbrella — the same import a typical consumer
                // uses, re-exporting ManifoldInference (and the other 80%-case
                // modules) so this conformance check fails fast if the
                // umbrella stops covering its documented contract.
                .product(name: "ManifoldKit", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStart"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
mkdir -p Sources/ColdStart
cat > Sources/ColdStart/main.swift <<'SWIFT'
import ManifoldKit
import Foundation

// MARK: - Inline fake backend
//
// A real downstream consumer would register MLX / Llama / Foundation. For the
// conformance test we want zero external dependencies (no model files, no OS
// availability) so we roll a minimal fake here. This is deliberately the
// *consumer-facing* shape — anything required to conform from outside the BCK
// monorepo must be public on `InferenceBackend`.

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

# 3. Build.
echo "==> swift build"
swift build --package-path . 2>&1 | tail -40

# 4. Run.
echo "==> swift run"
swift run --package-path . ColdStart
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start conformance: OK"
