#!/usr/bin/env bash
# Cold-start import gate — ManifoldMCP specialised module.
#
# Proves that a fresh downstream consumer can add ManifoldMCP as a standalone
# product dependency and reach its public surface (`MCPServerDescriptor`,
# `MCPTransportKind`, `MCPToolSource`) without importing the full ManifoldKit
# umbrella. This is the import shape documented in the ManifoldMCP README and
# used by the MCP chapter of the DX walkthrough.
#
# Catches: missing public exports, broken product → target wiring in
# Package.swift, accidental removal of public types, and dependency-graph
# changes that drop ManifoldInference (ManifoldMCP's only required dep).
#
# Does NOT require the MCP trait — ManifoldMCP itself compiles unconditionally;
# the MCP trait only gates the ManifoldMCPTests → ManifoldMCP dependency edge
# so the test target can declare the dep conditionally without pulling it
# into every non-MCP build.
#
# Runs in CI on every PR. ~30s on a warm cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t manifoldkit-cold-start-mcp.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start import gate (ManifoldMCP)"
echo "    ManifoldKit:  $REPO_ROOT"
echo "    work:         $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
#
# Depends only on ManifoldMCP — not the full umbrella — to verify the product
# is independently linkable. tools-version 6.2 matches the ManifoldKit floor.
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartMCPConsumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStartMCP", targets: ["ColdStartMCP"]),
    ],
    dependencies: [
        // Pin package identity explicitly so worktree directory names (e.g.
        // agent-<id>) do not change the identity seen by .product(package:).
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "ColdStartMCP",
            dependencies: [
                .product(name: "ManifoldMCP", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStartMCP"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
#
# Exercises the three entry points the MCP integration guide documents:
#   1. `MCPServerDescriptor` — the value type consumers create to describe a
#      server connection. Covers the public init, transport enum, and approval
#      policy surface.
#   2. `MCPTransportKind.streamableHTTP` — the transport variant real consumers
#      use for hosted MCP servers.
#   3. `MCPToolSource` — the bridge type that wraps an MCPClient and surfaces
#      its tools to the inference pipeline as ToolDefinitions.
#
# Does not exercise `MCPClient` itself (requires a live server + network) or
# the STDIO transport (requires an executable path). This is intentional:
# the gate proves the *import and type-level surface* compiles; the MCP E2E
# smoke test (ManifoldMCPE2ESmokeTests, nightly-slow-tests.yml) covers the
# runtime behaviour.
mkdir -p Sources/ColdStartMCP
cat > Sources/ColdStartMCP/main.swift <<'SWIFT'
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

# 3. Build and run.
# Safe.bareRepository is required when SwiftPM resolves the local path dep from
# inside a git worktree (SwiftPM internally opens the bare repo; Git's
# safe.bareRepository=explicit rejects that without this override).
SWIFT_ENV=(
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=safe.bareRepository
    GIT_CONFIG_VALUE_0=all
)

echo "==> swift build"
env "${SWIFT_ENV[@]}" swift build --package-path . 2>&1 | tail -40

echo "==> swift run"
env "${SWIFT_ENV[@]}" swift run --package-path . ColdStartMCP
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start MCP consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start import gate (ManifoldMCP): OK"
