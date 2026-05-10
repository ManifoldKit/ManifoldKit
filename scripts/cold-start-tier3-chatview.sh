#!/usr/bin/env bash
# Cold-start conformance - tier 3: ManifoldUI ChatView composition path.
#
# Tier 1 (`scripts/cold-start-conformance.sh`) covers the low-level
# InferenceService surface. Tier 2 (`scripts/cold-start-tier2-bootstrap.sh`)
# covers ManifoldBootstrap + ChatViewModel orchestration.
#
# Tier 3 covers the first SwiftUI screen a real app writes around ManifoldKit:
# a fresh consumer imports the public products, creates @Observable view models
# with @State, passes them through `.environment(_:)`, and constructs ChatView
# with a `@ViewBuilder apiConfiguration:` closure. This catches the two UI
# cold-start mistakes that do not appear in lower tiers: treating the view models
# as Combine `ObservableObject`s and forgetting the ChatView API-configuration
# builder shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="$REPO_ROOT/tmp/cold-start-tier3"
WORK="$WORK_ROOT/run-$$-$RANDOM"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start conformance (tier 3 - ChatView composition)"
echo "    ManifoldKit:  $REPO_ROOT"
echo "    work:         $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartTier3Consumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStartTier3", targets: ["ColdStartTier3"]),
    ],
    dependencies: [
        // Pin package identity explicitly so worktree directory names do not
        // change the dependency identity seen by .product(package:). The
        // FoundationOnly trait keeps this UI composition gate off the
        // MLX/Llama/HuggingFace dependency path; those backends are covered by
        // their own tests.
        .package(name: "ManifoldKit", path: "$REPO_ROOT", traits: ["FoundationOnly"]),
    ],
    targets: [
        .executableTarget(
            name: "ColdStartTier3",
            dependencies: [
                .product(name: "ManifoldKit", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStartTier3"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
mkdir -p Sources/ColdStartTier3
STORE_DIR="$WORK/swiftdata"
mkdir -p "$STORE_DIR"

cat > Sources/ColdStartTier3/main.swift <<SWIFT
import ManifoldKit
import SwiftData
import SwiftUI

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
    print("OK ChatView composed with @State/@Environment Observation and apiConfiguration builder")
    return 0
}

let exitCode = try await MainActor.run {
    try run()
}
exit(exitCode)
SWIFT

# 3. Build and run the consumer. Running evaluates the host RootView body once,
# which is enough to catch the public composition shape without launching a GUI.
# Some developer machines set `safe.bareRepository=explicit`; SwiftPM stores
# checkouts as bare repositories, so allow bare repos only for these subprocesses.
SWIFT_ENV=(
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=safe.bareRepository
    GIT_CONFIG_VALUE_0=all
)

echo "==> swift build"
env "${SWIFT_ENV[@]}" swift build --package-path . 2>&1 | tail -40

echo "==> swift run"
env "${SWIFT_ENV[@]}" swift run --package-path . ColdStartTier3
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start tier-3 consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start conformance (tier 3): OK"
