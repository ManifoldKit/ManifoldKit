#!/usr/bin/env bash
# scripts/_lib/consumer-scaffold.sh
#
# Shared helpers for the cold-start conformance / import gates
# (scripts/cold-start.sh, tiers 1-3 + the specialised-module gates). Each gate
# scaffolds a throwaway SwiftPM "consumer" package that links ManifoldKit by
# local path, builds it, and runs an executable target to prove some slice of
# the public surface works from *outside* the monorepo — the one thing an
# internal `swift test` run structurally cannot see (see
# docs/TESTING-CI-PRINCIPLES.md).
#
# This file is a LIBRARY, not an entry point. Source it; do not execute it:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib/consumer-scaffold.sh"
#
# It deliberately does not set `set -euo pipefail` itself — that is the
# sourcing script's call, and a library flipping shell options behind its
# caller's back is a classic footgun.
#
# Bash 3.2 compatible (CI runners ship Bash 3.2 — no `declare -A`, no
# `mapfile`, no `${var,,}`). Test under `/bin/bash`, not your dev shell.

# Guard against double-sourcing (harmless, but avoids redefining functions
# and re-running the trap-setup dance if a script sources this twice).
if [[ -n "${_MANIFOLDKIT_CONSUMER_SCAFFOLD_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_MANIFOLDKIT_CONSUMER_SCAFFOLD_LOADED=1

# cs_make_workdir <prefix> [repo_root]
#
# Creates a fresh scratch directory for the consumer package and registers a
# cleanup trap on EXIT. Sets the global $WORK to the new directory's absolute
# path.
#
#   - Called with one argument: uses a system tmpdir via
#     `mktemp -d -t "manifoldkit-<prefix>.XXXXXX"` (tiers 1/2, the
#     specialised-module gates).
#   - Called with a second argument (repo root): creates the workdir under
#     "<repo_root>/tmp/<prefix>/run-$$-$RANDOM" instead. This is tier 3's
#     historical behavior, preserved as-is — the original script gives no
#     rationale for diverging from mktemp, and "fixing" the inconsistency is
#     out of scope for this extraction (behavior-preserving refactor only).
cs_make_workdir() {
    local prefix="$1"
    local repo_root="${2:-}"

    if [[ -n "$repo_root" ]]; then
        WORK="$repo_root/tmp/$prefix/run-$$-$RANDOM"
        mkdir -p "$WORK"
    else
        WORK="$(mktemp -d -t "manifoldkit-${prefix}.XXXXXX")"
    fi

    # shellcheck disable=SC2064 # intentional: expand $WORK now, not at trap time.
    trap "rm -rf \"$WORK\"" EXIT
}

# cs_write_manifest <manifest_path> <package_name> <repo_root> <target_kind> <target_name> [dep...]
#
# Writes a scratch consumer Package.swift. <target_kind> is "executable" or
# "library". Remaining positional args are ManifoldKit product names to link
# (e.g. "ManifoldKit", or "ManifoldInference ManifoldRuntime ...").
#
# tools-version 6.2 + platforms [.macOS(.v15)] matches every cold-start gate's
# floor: 6.2 is required for source that calls `.macOS(.v26)`-gated API
# elsewhere in the dependency graph, and pinning platforms to .v15
# (ManifoldKit's n-1 floor) keeps the consumer buildable on every macOS
# ManifoldKit supports, not just the latest.
#
# The dependency identity is pinned explicitly via `name: "ManifoldKit"`
# rather than letting SwiftPM derive it from `.package(path:)`'s last path
# component — a plain checkout's directory is already named `ManifoldKit`,
# but a git worktree (e.g. `ManifoldKit-worktrees/agent-<id>`) would otherwise
# resolve to the wrong identity and break `.product(package: "ManifoldKit")`
# lookups. See CLAUDE.md's "SwiftPM local-package consumers need explicit
# name:" note.
cs_write_manifest() {
    local manifest_path="$1"; shift
    local package_name="$1"; shift
    local repo_root="$1"; shift
    local target_kind="$1"; shift
    local target_name="$1"; shift
    # remaining args ($@): product dependency names

    local product_decl target_decl
    if [[ "$target_kind" == "library" ]]; then
        product_decl=".library(name: \"$target_name\", targets: [\"$target_name\"])"
        target_decl=".target("
    else
        product_decl=".executable(name: \"$target_name\", targets: [\"$target_name\"])"
        target_decl=".executableTarget("
    fi

    local deps_block=""
    local dep
    for dep in "$@"; do
        deps_block="${deps_block}                .product(name: \"${dep}\", package: \"ManifoldKit\"),
"
    done

    cat > "$manifest_path" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "$package_name",
    platforms: [.macOS(.v15)],
    products: [
        $product_decl,
    ],
    dependencies: [
        .package(name: "ManifoldKit", path: "$repo_root"),
    ],
    targets: [
        $target_decl
            name: "$target_name",
            dependencies: [
$deps_block            ],
            path: "Sources/$target_name"
        ),
    ]
)
EOF
}

# cs_swift_build <package_path> [--build-path <dir>]
#
# Runs `swift build` against the scaffolded consumer and prints the tail of
# its combined output. Returns swift build's real exit code.
#
# Deliberately does NOT pipe the build through `tail` and inspect `$?`
# afterwards — that loses the build's exit status unless `pipefail` happens
# to be set by the caller, which is fragile to depend on across sourcing
# contexts. Instead the output is captured to a temp file so the exit code is
# read directly from the command that produced it.
#
# `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0` relax `safe.bareRepository` for this
# subprocess only: SwiftPM stores its local-path dependency checkout as a bare
# repository internally, and a developer machine with
# `safe.bareRepository=explicit` would otherwise reject it. Applied
# unconditionally (previously only tiers 3+ and the specialised-module gates
# did this) — it is a pure permission relaxation for a git subprocess call and
# cannot change build output, so unifying it is behavior-preserving.
cs_swift_build() {
    local package_path="$1"; shift
    local build_path=""
    if [[ "${1:-}" == "--build-path" ]]; then
        build_path="$2"
        shift 2
    fi

    local build_env=(
        GIT_CONFIG_COUNT=1
        GIT_CONFIG_KEY_0=safe.bareRepository
        GIT_CONFIG_VALUE_0=all
    )

    local -a build_args=(swift build --package-path "$package_path")
    if [[ -n "$build_path" ]]; then
        build_args+=(--build-path "$build_path")
    fi

    local build_log
    build_log="$(mktemp -t manifoldkit-cs-build.XXXXXX)"

    echo "==> swift build"
    local build_status=0
    if ! env "${build_env[@]}" "${build_args[@]}" > "$build_log" 2>&1; then
        build_status=1
    fi

    tail -n 60 "$build_log"
    rm -f "$build_log"

    return $build_status
}

# cs_swift_run <package_path> <executable_target_name>
#
# Runs the scaffolded consumer's executable target and streams its output
# directly (no capture — the consumer's stdout/stderr IS the test signal).
# Returns swift run's real exit code. Same bare-repository relaxation as
# cs_swift_build, for the same reason.
cs_swift_run() {
    local package_path="$1"
    local exec_name="$2"

    local run_env=(
        GIT_CONFIG_COUNT=1
        GIT_CONFIG_KEY_0=safe.bareRepository
        GIT_CONFIG_VALUE_0=all
    )

    echo "==> swift run"
    env "${run_env[@]}" swift run --package-path "$package_path" "$exec_name"
}
