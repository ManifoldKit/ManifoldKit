#!/usr/bin/env bash
# scripts/test-sandboxed.sh — Run ManifoldKit's local-only test suites under
# `sandbox-exec` with a net-deny profile.
#
# Phase 5 of #714. `DenyAllURLProtocol` (Phase 1, PR #715) intercepts
# `URLSession` traffic but cannot see `Network.framework`, raw BSD sockets,
# `getaddrinfo(3)`, mDNS/Bonjour, `CFStream`, or `Process.launch` of curl.
# `TrafficBoundaryAuditTest` rule 2 catches these at the **source** level,
# but a transitive dependency or a creative regression could still bypass
# the source audit. This script adds a second runtime layer at the **OS
# sandbox boundary** — any outbound network attempt by the test binary
# triggers a sandbox violation, killing the test before it can leak.
#
# ── Why we run `xctest` directly, not `swift test` ────────────────────────────
#
# `swift test` recompiles the package manifest on every invocation and the
# manifest builder *itself* shells out to `sandbox-exec` for SwiftPM's own
# isolation. Nesting `sandbox-exec` inside `sandbox-exec` fails with
# `sandbox_apply: Operation not permitted`, so we cannot wrap `swift test`.
# Instead we build the test bundle *outside* the sandbox with `swift build
# --build-tests`, then invoke the resulting `.xctest` bundle under the
# sandbox via `xcrun xctest`. The bundle still loads dylibs and reads
# fixtures normally; only network syscalls are denied.
#
# ── Profile ───────────────────────────────────────────────────────────────────
#
# `(allow default)` keeps file I/O, `mach*`, `ipc*`, `process*`, signals,
# and POSIX-IPC open — without these, XCTest's reporter and Process
# subreaping crash on startup, hiding whether any actual network attempt
# happened. `(deny network*)` covers the entire `network` action class:
#   - network-outbound  (TCP/UDP connect, sendto)
#   - network-inbound   (bind/listen)
#   - network-bind
#   - network*-resolution (gates getaddrinfo / DNS)
# Loopback (`127.0.0.1`, `::1`) and Unix-domain sockets are subject to the
# same `network*` rules — local-only test fixtures that bind a TCP socket
# (e.g., a mock SSE server) will fail under this profile. Those tests
# belong outside this harness.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   scripts/test-sandboxed.sh
#       Builds tests, then runs the SandboxExecNetDenyTests harness checks
#       under the deny profile (a smoke-only default; cheap and fast).
#
#   scripts/test-sandboxed.sh --filter <XCTest path>
#       Forwards `-XCTest <path>` to the underlying `xctest` invocation.
#       Path is the XCTest selector, e.g.:
#           ManifoldTestSupportTests.DenyAllURLProtocolTests
#           ManifoldInferenceTests.SomeSuite/testCase
#
#   scripts/test-sandboxed.sh --bundle <path-to-.xctest>
#       Override the bundle path (default: the ManifoldKitPackageTests
#       bundle under `.build/<arch>-apple-macosx/debug/`).

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_FILE="${TMPDIR:-/tmp}/bck-deny-net-$$.sb"

cleanup() {
    rm -f "$PROFILE_FILE"
}
trap cleanup EXIT

# ── Platform gate ─────────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "skip: sandbox-exec is macOS-only (host: $(uname -s))" >&2
    exit 0
fi

if [[ ! -x /usr/bin/sandbox-exec ]]; then
    echo "error: /usr/bin/sandbox-exec not found — required for net-deny isolation" >&2
    exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

FILTER=""
BUNDLE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --bundle)
            BUNDLE_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "Usage: $0 [--filter <XCTest selector>] [--bundle <path>]" >&2
            exit 2
            ;;
    esac
done

# ── Profile ───────────────────────────────────────────────────────────────────

cat > "$PROFILE_FILE" <<'SBPL'
(version 1)
(allow default)
(deny network*)
SBPL

# ── Build (outside sandbox) ───────────────────────────────────────────────────
#
# `swift build --build-tests` runs under SwiftPM's own sandbox; doing it
# *outside* our deny-network sandbox avoids the nested-sandbox failure
# described in the header comment.

cd "$PACKAGE_DIR"

echo "==> building tests (outside sandbox)…"
swift build --build-tests --disable-default-traits >/dev/null

# ── Locate test bundle ────────────────────────────────────────────────────────

if [[ -n "$BUNDLE_OVERRIDE" ]]; then
    BUNDLE="$BUNDLE_OVERRIDE"
else
    ARCH="$(uname -m)"
    BUNDLE=".build/${ARCH}-apple-macosx/debug/ManifoldKitPackageTests.xctest"
fi

if [[ ! -d "$BUNDLE" ]]; then
    echo "error: test bundle not found at $BUNDLE" >&2
    exit 1
fi

# ── Run the test bundle under the sandbox ─────────────────────────────────────
#
# Default selector: only the harness's own self-test. The harness asserts
# the deny profile blocks curl + NWConnection while leaving local-only
# commands working — a tight smoke that proves the OS-level boundary is
# intact. Suites that should run *under* this isolation in CI are passed
# via `--filter`.

if [[ -z "$FILTER" ]]; then
    FILTER="ManifoldTestSupportTests.SandboxExecNetDenyTests"
fi

echo "==> sandbox-exec profile: $PROFILE_FILE"
cat "$PROFILE_FILE"
echo "==> bundle: $BUNDLE"
echo "==> filter: $FILTER"
echo

# `exec` so the sandbox's exit status (sandbox-violation kill or
# child's natural status) becomes this script's exit status — CI
# steps see a non-zero exit on any leak.
exec /usr/bin/sandbox-exec -f "$PROFILE_FILE" \
    /usr/bin/xcrun xctest -XCTest "$FILTER" "$BUNDLE"
