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
# Modes:
#   offline   No network backends. `--disable-default-traits`.
#   ollama    Self-hosted Ollama only. `--disable-default-traits --traits Ollama`.
#   saas      Cloud SaaS only. `--disable-default-traits --traits CloudSaaS`.
#   full      Everything. `--traits MLX,Llama,Ollama,CloudSaaS` (default-traits enabled).
#   all       Run every mode in sequence.
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

# Trait flags per mode. `--disable-default-traits` strips MLX+Llama (the
# default set) so that offline really means offline. `full` keeps the defaults
# and layers Ollama+CloudSaaS on top.
traits_for_mode() {
  case "$1" in
    offline) echo "--disable-default-traits" ;;
    ollama)  echo "--disable-default-traits --traits Ollama" ;;
    saas)    echo "--disable-default-traits --traits CloudSaaS" ;;
    full)    echo "--traits MLX,Llama,Ollama,CloudSaaS" ;;
    *)
      echo "Unknown mode: $1 (expected offline|ollama|saas|full)" >&2
      exit 2
      ;;
  esac
}

# Symbols that must NOT appear in modes which exclude the CloudSaaS trait.
# Matched against `nm -gU` output, which surfaces both the Swift mangled form
# (`$s17ManifoldBackends13ClaudeBackendC`) and the Obj-C metaclass form
# (`_OBJC_CLASS_$_ManifoldBackends.ClaudeBackend`). Catches both runtime
# entry points (Tin-foil-hat SEV-2.6 in the plan).
CLOUD_SYMBOLS=(
  "ClaudeBackend"
  "OpenAIBackend"
  "OpenAIResponsesBackend"
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
  local traits
  traits=$(traits_for_mode "$mode")

  echo ""
  echo "=== build-modes: building [$mode] (debug) ==="
  echo "    swift build $traits"
  # shellcheck disable=SC2086
  swift build $traits
}

audit_mode() {
  local mode="$1"
  local traits
  traits=$(traits_for_mode "$mode")

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
  echo "    swift build -c release $traits"
  # shellcheck disable=SC2086
  swift build -c release $traits

  mkdir -p "$ARTIFACT_DIR/$mode"

  # Locate the ManifoldBackends release object directory. SwiftPM emits per-
  # target build folders under .build/<arch>-apple-macosx/release/<Target>.build/.
  local backends_dir
  backends_dir=$(find .build -type d -path '*/release/ManifoldBackends.build' 2>/dev/null | head -n 1 || true)

  local audit_failures=0

  if [[ -z "$backends_dir" ]]; then
    echo "    note: ManifoldBackends.build not found — module excluded from this mode."
  else
    echo "    ManifoldBackends.build at: $backends_dir"

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
    done < <(find "$backends_dir" -name '*.o' -print0)

    # otool -L runs against the linked dylib if one was produced; SwiftPM
    # produces a static archive for libraries by default, so this is a best-
    # effort capture for the artifact rather than a hard gate.
    local backends_dylib
    backends_dylib=$(find .build -type f \( -name 'libManifoldBackends.dylib' -o -name 'ManifoldBackends.o' \) 2>/dev/null | head -n 1 || true)
    if [[ -n "$backends_dylib" ]]; then
      {
        echo "### $backends_dylib"
        otool -L "$backends_dylib" 2>/dev/null || true
      } >> "$otool_out"
    fi

    # Audit gate: in modes WITHOUT CloudSaaS, no cloud symbols must appear.
    # `grep -F` (fixed strings) avoids regex surprises if a symbol name ever
    # contains a metacharacter; it also avoids matching the per-object-path
    # `### …` headers because we wrote a header-free `$nm_out`.
    if [[ "$mode" == "offline" || "$mode" == "ollama" ]]; then
      echo ""
      echo "    asserting NO cloud symbols in [$mode]"
      for sym in "${CLOUD_SYMBOLS[@]}"; do
        if grep -Fq "$sym" "$nm_out"; then
          echo "::error::build-modes audit [$mode]: cloud symbol '$sym' present in ManifoldBackends release objects"
          grep -F "$sym" "$nm_out" | head -n 5 >&2 || true
          audit_failures=$((audit_failures + 1))
        fi
      done

      # Hostname literals in ManifoldBackends. APIProvider.swift in
      # ManifoldInference legitimately holds these as data — that module is
      # intentionally out of scope here (see SECURITY.md).
      if [[ "$mode" == "offline" ]]; then
        echo "    asserting NO cloud hostname literals in [$mode]"
        for host in "${CLOUD_HOSTS[@]}"; do
          # `grep -F` (fixed strings) is required — `$host` contains dots,
          # which would otherwise match arbitrary characters in default BRE.
          if grep -Fq "$host" "$strings_ascii_out" || grep -Fq "$host" "$strings_utf16_out"; then
            echo "::error::build-modes audit [$mode]: hostname literal '$host' present in ManifoldBackends release objects"
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
