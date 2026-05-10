#!/usr/bin/env bash
# Exercise the SourceKit stale-module diagnostic path from issue #1109 without
# deleting the repository's normal .build directory or Xcode DerivedData.
#
# By default this is a dry run. Pass --run to execute the commands against an
# isolated SwiftPM scratch path under .build/sourcekit-1109-diagnostics.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/sourcekit-stale-module-diagnostics.sh [--run] [--collect-diagnose] [--scratch-path PATH]

Dry-run by default. The --run path:
  1. Builds ManifoldKit with --disable-default-traits.
  2. Builds ManifoldKit again with the default trait set, reusing the same scratch path.
  3. Runs sourcekit-lsp debug index against the package with that scratch path.
  4. Scans the SourceKit-LSP output for "No such module 'ManifoldPersistenceSwiftData'".

The script is intentionally non-destructive:
  - no git reset/clean
  - no rm -rf .build
  - no writes outside the repository

Options:
  --run               Execute the diagnostic sequence.
  --collect-diagnose  Also write a sourcekit-lsp diagnose bundle with swift-version metadata only.
  --scratch-path PATH Use a custom scratch path (default: .build/sourcekit-1109-diagnostics).
  -h, --help          Show this help.
USAGE
}

RUN=0
COLLECT_DIAGNOSE=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCH_PATH="$REPO_ROOT/.build/sourcekit-1109-diagnostics"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN=1
      shift
      ;;
    --collect-diagnose)
      COLLECT_DIAGNOSE=1
      shift
      ;;
    --scratch-path)
      if [[ $# -lt 2 ]]; then
        echo "error: --scratch-path requires a value" >&2
        exit 64
      fi
      SCRATCH_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$SCRATCH_PATH" != /* ]]; then
  SCRATCH_PATH="$REPO_ROOT/$SCRATCH_PATH"
fi

if [[ "$SCRATCH_PATH" != "$REPO_ROOT"/.build/* ]]; then
  echo "error: scratch path must live under $REPO_ROOT/.build for this non-destructive diagnostic" >&2
  exit 64
fi

LOG_PATH="$SCRATCH_PATH/sourcekit-lsp-debug-index.log"

print_plan() {
  cat <<PLAN
Repository: $REPO_ROOT
Scratch path: $SCRATCH_PATH
SourceKit-LSP log: $LOG_PATH

Commands:
  mkdir -p "$SCRATCH_PATH"
  swift --version
  sourcekit-lsp --version || true
  swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" --disable-default-traits --target ManifoldKit
  swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" --target ManifoldKit
  sourcekit-lsp --scratch-path "$SCRATCH_PATH" debug index --project "$REPO_ROOT" 2>&1 | tee "$LOG_PATH"
  grep -F "No such module 'ManifoldPersistenceSwiftData'" "$LOG_PATH"
PLAN
}

if [[ "$RUN" -eq 0 ]]; then
  print_plan
  echo
  echo "Dry run only. Re-run with --run to execute."
  exit 0
fi

mkdir -p "$SCRATCH_PATH"

echo "Swift version:"
swift --version

echo
echo "SourceKit-LSP version:"
sourcekit-lsp --version || true

echo
echo "Building ManifoldKit with traits disabled..."
swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" --disable-default-traits --target ManifoldKit

echo
echo "Building ManifoldKit with default traits, reusing the same scratch path..."
swift build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" --target ManifoldKit

echo
echo "Indexing with SourceKit-LSP..."
sourcekit-lsp --scratch-path "$SCRATCH_PATH" debug index --project "$REPO_ROOT" 2>&1 | tee "$LOG_PATH"

if grep -Fq "No such module 'ManifoldPersistenceSwiftData'" "$LOG_PATH"; then
  echo
  echo "Reproduced stale SourceKit module diagnostic. See: $LOG_PATH"
  exit 2
fi

echo
echo "Did not reproduce the stale module diagnostic in SourceKit-LSP debug index output."
echo "If Xcode still shows the diagnostic, capture the long-lived editor state with:"
echo "  scripts/sourcekit-stale-module-diagnostics.sh --run --collect-diagnose"

if [[ "$COLLECT_DIAGNOSE" -eq 1 ]]; then
  DIAGNOSE_PATH="$SCRATCH_PATH/sourcekit-lsp-diagnose-$(date +%Y%m%d-%H%M%S)"
  echo
  echo "Writing SourceKit-LSP diagnose bundle to $DIAGNOSE_PATH"
  sourcekit-lsp diagnose --components swift-versions --bundle-output-path "$DIAGNOSE_PATH"
fi
