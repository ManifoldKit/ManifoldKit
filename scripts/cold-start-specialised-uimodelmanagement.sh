#!/usr/bin/env bash
# Cold-start import gate — ManifoldUIModelManagement specialised module.
#
# Proves that a fresh downstream consumer can add ManifoldUIModelManagement as
# a standalone product dependency and reach its public surface
# (`ModelManagementViewModel`, `DocumentLibraryViewModel`, `ModelImportError`)
# without importing the full ManifoldKit umbrella.
#
# Catches: missing public exports, broken product → target wiring in
# Package.swift, accidental removal of public types, and dependency-graph
# changes that drop ManifoldUI / ManifoldRuntime / ManifoldInference (all of
# which ManifoldUIModelManagement depends on unconditionally).
#
# ManifoldUIModelManagement compiles unconditionally — the HuggingFace
# trait only adds conditional-compilation defines that expand model
# source and API-key editor surface. The gate runs without those traits so it
# exercises the baseline, always-present slice.
#
# Runs in CI on every PR. ~30s on a warm cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t manifoldkit-cold-start-uimm.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cold-start import gate (ManifoldUIModelManagement)"
echo "    ManifoldKit:  $REPO_ROOT"
echo "    work:         $WORK"

cd "$WORK"

# 1. Scaffold consumer Package.swift.
#
# Depends on ManifoldUIModelManagement alone (not the umbrella) to verify the
# product is independently linkable. tools-version 6.2 matches ManifoldKit.
cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartUIMMConsumer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ColdStartUIModelManagement", targets: ["ColdStartUIModelManagement"]),
    ],
    dependencies: [
        // Pin package identity explicitly so worktree directory names do not
        // change the identity seen by .product(package:).
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "ColdStartUIModelManagement",
            dependencies: [
                .product(name: "ManifoldUIModelManagement", package: "ManifoldKit"),
            ],
            path: "Sources/ColdStartUIModelManagement"
        ),
    ]
)
EOF

# 2. Scaffold consumer source.
#
# Exercises the three primary entry points the model management integration
# guide documents:
#   1. `ModelManagementViewModel()` — the zero-argument init that produces a
#      non-functional view model (no HuggingFace service, no download manager).
#      This is the shape consumers use in previews and unit tests.
#   2. `ModelImportError` — the error type consumers catch when local-file
#      import fails (e.g. unsupported format, duplicate model ID).
#   3. `DocumentLibraryViewModel` — the document-library counterpart; verifies
#      that both view model products are accessible from the same import.
#
# Does NOT exercise network paths (HuggingFace search, download manager) — those
# require API keys and live connectivity. The type-level surface check is the
# meaningful gate; the ManifoldUIModelManagementTests suite covers behaviour.
mkdir -p Sources/ColdStartUIModelManagement
cat > Sources/ColdStartUIModelManagement/main.swift <<'SWIFT'
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
env "${SWIFT_ENV[@]}" swift run --package-path . ColdStartUIModelManagement
EXIT=$?

if [[ $EXIT -ne 0 ]]; then
    echo "FAIL: cold-start UIModelManagement consumer exited with $EXIT"
    exit $EXIT
fi

echo "==> Cold-start import gate (ManifoldUIModelManagement): OK"
