#!/usr/bin/env bash
# scripts/build-modes.sh — Build ManifoldKit in each documented build mode and
# optionally run a binary symbol audit against the produced object files.
#
# This is Phase 3 of #714. It is the single entrypoint for the build-mode CI
# matrix (.github/workflows/build-modes.yml) and for local repro of the audit.
#
# Usage:
#   scripts/build-modes.sh <mode> [--build-only|--audit]
#
# Modes (v0.48 PR A4 — the Ollama/CloudSaaS traits are retired; cloud sources
# always compile, so the modes are now PRODUCT-scoped builds. The audit claim
# shifted from compile-out — "the trait excluded the source" — to link-out —
# "the product dependency graph never includes the module". Decision #4 of the
# v0.48 plan accepted this artifact-series discontinuity; the per-mode
# artifact files keep their names and cadence.):
#   offline   Chat stack with no backend products: `--disable-default-traits
#             --target ManifoldUI`. No cloud module in the graph.
#   ollama    Self-hosted family only: `--disable-default-traits --target
#             ManifoldOllama`. ManifoldCloudCore (shared TLS-pinning/SSE
#             infra) IS in this graph; the SaaS backends are not.
#   saas      SaaS family only: `--disable-default-traits --target
#             ManifoldCloudSaaS`.
#   full      Everything: plain `swift build` (default traits MLX/Llama/
#             HuggingFace; cloud is always compiled).
#   all       Run every mode in sequence.
#
# `--target`, not `--product`: `swift build --product <automatic library>`
# does NOT prune the build to the product's graph (it compiles every target
# in the package — verified empirically), which would put SaaS objects in
# every mode's scan. `--target` builds exactly the target's dependency
# closure. The audit additionally wipes the release object dir before each
# build so a scan can never pass (or fail) on stale objects from a previous
# mode or branch.
#
# Subcommands:
#   --build-only  Build the mode (debug). Default when no subcommand given.
#   --audit       Build release + run nm/strings/otool audit, exits non-zero on
#                 cloud-symbol or hostname-literal regressions.
#
# Honest scoping (per #714 plan): this is defense in depth, not authoritative
# proof. String obfuscation defeats the strings pass. The audit catches lazy
# regressions, not adversarial ones — see SECURITY.md.

set -euo pipefail

MODE="${1:-}"
SUBCOMMAND="${2:---build-only}"

if [[ -z "$MODE" ]]; then
  echo "Usage: scripts/build-modes.sh <offline|ollama|saas|full|all> [--build-only|--audit]" >&2
  exit 2
fi

# Build arguments per mode. Product-scoped since v0.48 (see header):
# excluding cloud code is a link-out decision at the product edge, not a
# compile flag. `--disable-default-traits` additionally strips MLX+Llama so
# the offline/family graphs stay minimal.
build_args_for_mode() {
  case "$1" in
    offline) echo "--disable-default-traits --target ManifoldUI" ;;
    ollama)  echo "--disable-default-traits --target ManifoldOllama" ;;
    saas)    echo "--disable-default-traits --target ManifoldCloudSaaS" ;;
    full)    echo "" ;;
    *)
      echo "Unknown mode: $1 (expected offline|ollama|saas|full)" >&2
      exit 2
      ;;
  esac
}

# Symbols that must NOT appear in modes which exclude the SaaS product.
# Matched against `nm -gU` output, which surfaces both the Swift mangled form
# (`$s17ManifoldCloudSaaS13ClaudeBackendC`) and the Obj-C metaclass form.
# Catches both runtime entry points (Tin-foil-hat SEV-2.6 in the plan).
SAAS_SYMBOLS=(
  "ClaudeBackend"
  "OpenAIBackend"
  "OpenAIResponsesBackend"
)

# Additionally banned in OFFLINE mode only. PinnedSessionDelegate lives in
# ManifoldCloudCore — shared TLS-pinning infrastructure that the Ollama
# product legitimately links (discontinuity vs the pre-v0.48 trait-mode
# audit, where the umbrella-scoped scan never saw it at all).
OFFLINE_ONLY_SYMBOLS=(
  "PinnedSessionDelegate"
)

# Hostnames that must NOT appear in offline mode. `api.ollama.com` is included
# as a forward-looking guard in case a future Ollama Cloud product lands;
# self-hosted Ollama uses `localhost:11434`, so the marketing domain is a
# legitimate canary.
CLOUD_HOSTS=(
  "api.anthropic.com"
  "api.openai.com"
  "api.ollama.com"
)

# Frameworks that an offline build should NEVER link against. We only assert
# this for explicit DSOs the offline binary should not need; the runtime
# always-link list (Foundation etc.) is intentionally not policed here.
OFFLINE_BANNED_DYLIBS=(
  # Currently empty: ManifoldInference uses URLSession from Foundation, which
  # is unavoidable. The ban-list is kept as a hook for future extraction
  # (e.g., if URLSessionProvider is moved into a CloudSaaS-gated module).
)

ARTIFACT_DIR="${BUILD_MODES_ARTIFACT_DIR:-build-modes-audit}"

build_mode() {
  local mode="$1"
  local build_args
  build_args=$(build_args_for_mode "$mode")

  echo ""
  echo "=== build-modes: building [$mode] (debug) ==="
  echo "    swift build $build_args"
  # shellcheck disable=SC2086
  swift build $build_args
}

audit_mode() {
  local mode="$1"
  local build_args
  build_args=$(build_args_for_mode "$mode")

  # The audit relies on Darwin-only flags (`nm -gU`, `otool -L`, `strings -e l`)
  # against Mach-O object files. Refuse to run on non-macOS rather than emit
  # a silently-empty "clean" report that could be mistaken for procurement
  # evidence. SwiftPM on Linux produces ELF objects which `nm -gU` rejects.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "::error::build-modes audit requires macOS (Darwin nm/otool/strings); got $(uname -s)" >&2
    return 2
  fi

  echo ""
  echo "=== build-modes: auditing [$mode] (release) ==="

  # Clean-room scan: wipe the release object dir first so the symbol scan
  # below can only see objects produced by THIS mode's build. Without this,
  # a previous mode (or branch) leaves stale .o files in release/ and the
  # whole-graph scan reports them as violations (or silently vouches for a
  # graph it didn't build).
  find .build -maxdepth 2 -type d -name 'release' -path '*-apple-macosx*' -exec rm -rf {} + 2>/dev/null || true

  echo "    swift build -c release $build_args"
  # shellcheck disable=SC2086
  swift build -c release $build_args

  mkdir -p "$ARTIFACT_DIR/$mode"

  # Scan the ENTIRE product build graph (every <Target>.build directory under
  # release/), not just the umbrella. Product-scoped modes make the link-out
  # claim at the product edge: a banned symbol anywhere in the graph means the
  # product's dependency closure includes a module it must not.
  local release_dir
  release_dir=$(find .build -type d -name 'release' -path '*-apple-macosx*' 2>/dev/null | head -n 1 || true)

  local audit_failures=0

  if [[ -z "$release_dir" ]]; then
    echo "::error::build-modes audit [$mode]: release build directory not found" >&2
    return 1
  else
    echo "    scanning release graph at: $release_dir"

    # Snapshot per-mode artifacts for the procurement evidence archive.
    # `nm.txt` is the *gating* file: every line in it must be a real symbol
    # (no per-object path headers) so that grepping for `ClaudeBackend` etc.
    # cannot match an object filename like `### .../ClaudeBackend.swift.o`
    # and trigger a false positive. The strings/otool files keep their
    # `### path` headers because they're informational — the offline-mode
    # gate against them is hostname-string matching, which is unaffected.
    local nm_out="$ARTIFACT_DIR/$mode/nm.txt"
    local nm_headers_out="$ARTIFACT_DIR/$mode/nm-by-object.txt"
    local strings_ascii_out="$ARTIFACT_DIR/$mode/strings-ascii.txt"
    local strings_utf16_out="$ARTIFACT_DIR/$mode/strings-utf16.txt"
    local otool_out="$ARTIFACT_DIR/$mode/otool.txt"

    : > "$nm_out"
    : > "$nm_headers_out"
    : > "$strings_ascii_out"
    : > "$strings_utf16_out"
    : > "$otool_out"

    # Iterate object files. nm/strings on the directory itself doesn't recurse,
    # and SwiftPM produces one .o per source file plus a master .swiftmodule.
    while IFS= read -r -d '' obj; do
      # Symbols only — no path header — into the gating file.
      nm -gU "$obj" 2>/dev/null >> "$nm_out" || true

      # Per-object grouped view kept as a separate artifact for humans.
      {
        echo "### $obj"
        nm -gU "$obj" 2>/dev/null || true
      } >> "$nm_headers_out"

      {
        echo "### $obj"
        strings -a "$obj" 2>/dev/null || true
      } >> "$strings_ascii_out"

      {
        echo "### $obj"
        # `strings -e l` reads 16-bit little-endian (UTF-16LE) — Swift's
        # `String` is stored as UTF-8 on disk, but constant initialisers can
        # surface as UTF-16 when bridged through ObjC NSString or NSURL.
        strings -a -e l "$obj" 2>/dev/null || true
      } >> "$strings_utf16_out"
    done < <(find "$release_dir" -path '*.build/*' -name '*.o' \
               ! -name 'APIProvider.swift.o' \
               ! -name 'BackendDescriptor.swift.o' \
               ! -name 'APIEndpointRecord.swift.o' -print0)
    # Excluded objects hold provider hostnames as *data*, not cloud code:
    # APIProvider.swift / BackendDescriptor.swift (ManifoldHardware) carry
    # defaultBaseURL metadata for the provider registry; APIEndpointRecord
    # (ManifoldModelCatalog) carries per-provider endpoint defaults. Every
    # mode links these leaf modules. Same scoping exemption as the
    # pre-v0.48 audit documented in SECURITY.md. None of them define any
    # symbol on the banned lists, so excluding them from the nm scan too
    # is safe and keeps the find expression single-purpose.

    # otool -L runs against linked dylibs if any were produced; SwiftPM
    # produces static archives for libraries by default, so this is a best-
    # effort capture for the artifact rather than a hard gate.
    local linked_dylib
    linked_dylib=$(find "$release_dir" -maxdepth 1 -type f -name '*.dylib' 2>/dev/null | head -n 1 || true)
    if [[ -n "$linked_dylib" ]]; then
      {
        echo "### $linked_dylib"
        otool -L "$linked_dylib" 2>/dev/null || true
      } >> "$otool_out"
    fi

    # Audit gate: in modes that exclude the SaaS product, no SaaS symbols
    # must appear anywhere in the product graph. `grep -F` (fixed strings)
    # avoids regex surprises if a symbol name ever contains a metacharacter;
    # it also avoids matching the per-object-path `### …` headers because we
    # wrote a header-free `$nm_out`.
    if [[ "$mode" == "offline" || "$mode" == "ollama" ]]; then
      echo ""
      echo "    asserting NO SaaS symbols in [$mode]"
      for sym in "${SAAS_SYMBOLS[@]}"; do
        if grep -Fq "$sym" "$nm_out"; then
          echo "::error::build-modes audit [$mode]: SaaS symbol '$sym' present in the [$mode] product graph"
          grep -F "$sym" "$nm_out" | head -n 5 >&2 || true
          audit_failures=$((audit_failures + 1))
        fi
      done

      if [[ "$mode" == "offline" ]]; then
        # Offline additionally bans the shared cloud-networking infra that the
        # ollama product legitimately links via ManifoldCloudCore.
        for sym in "${OFFLINE_ONLY_SYMBOLS[@]}"; do
          if grep -Fq "$sym" "$nm_out"; then
            echo "::error::build-modes audit [offline]: cloud-infra symbol '$sym' present in the offline product graph"
            grep -F "$sym" "$nm_out" | head -n 5 >&2 || true
            audit_failures=$((audit_failures + 1))
          fi
        done
      fi

      # Hostname literals anywhere in the offline product graph.
      # APIProvider.swift (ManifoldHardware) legitimately holds these as
      # data and is excluded from the scan above (see SECURITY.md).
      if [[ "$mode" == "offline" ]]; then
        echo "    asserting NO cloud hostname literals in [$mode]"
        for host in "${CLOUD_HOSTS[@]}"; do
          # `grep -F` (fixed strings) is required — `$host` contains dots,
          # which would otherwise match arbitrary characters in default BRE.
          if grep -Fq "$host" "$strings_ascii_out" || grep -Fq "$host" "$strings_utf16_out"; then
            echo "::error::build-modes audit [$mode]: hostname literal '$host' present in the offline product graph"
            audit_failures=$((audit_failures + 1))
          fi
        done

        # otool -L ban list — currently empty, but the loop is wired up so
        # adding entries to OFFLINE_BANNED_DYLIBS later doesn't need code
        # changes here. The `${arr[@]+"${arr[@]}"}` form is the canonical
        # bash-3.2-safe expansion for a possibly-empty array under `set -u`
        # (macOS still ships bash 3.2 by default).
        for dylib in ${OFFLINE_BANNED_DYLIBS[@]+"${OFFLINE_BANNED_DYLIBS[@]}"}; do
          if grep -Fq "$dylib" "$otool_out"; then
            echo "::error::build-modes audit [offline]: banned dylib '$dylib' linked"
            audit_failures=$((audit_failures + 1))
          fi
        done
      fi
    else
      echo "    [$mode] is a cloud build — symbol/host audit is informational only"
    fi
  fi

  if (( audit_failures > 0 )); then
    echo ""
    echo "build-modes audit [$mode]: $audit_failures failure(s)"
    return 1
  fi

  echo "build-modes audit [$mode]: clean"
  return 0
}

run_mode() {
  local mode="$1"
  local sub="$2"

  case "$sub" in
    --build-only)
      build_mode "$mode"
      ;;
    --audit)
      audit_mode "$mode"
      ;;
    *)
      echo "Unknown subcommand: $sub" >&2
      exit 2
      ;;
  esac
}

if [[ "$MODE" == "all" ]]; then
  exit_code=0
  for m in offline ollama saas full; do
    if ! run_mode "$m" "$SUBCOMMAND"; then
      exit_code=1
    fi
  done
  exit "$exit_code"
else
  run_mode "$MODE" "$SUBCOMMAND"
fi
