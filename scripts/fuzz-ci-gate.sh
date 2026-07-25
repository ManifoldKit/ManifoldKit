#!/usr/bin/env bash
# scripts/fuzz-ci-gate.sh — Gate a fuzz campaign's findings against an allowlist.
#
# Usage:
#   scripts/fuzz-ci-gate.sh <path-to-tmp/fuzz/index.json> [path-to-allowlist.json]
#
# Exit codes:
#   0   — no findings, or every finding is covered by an unexpired allowlist entry.
#   1   — one or more findings are not covered, an allowlist entry has expired,
#         or index.json is missing (a campaign that never wrote one never ran —
#         see the missing-index branch below).
#   2   — usage / input-parse error.
#
# The allowlist JSON shape is:
#   { "allowlist": [ { "hash": "<12-char>", "reason": "<prose>", "expires": "YYYY-MM-DD" } ] }
# The `expires` date is inclusive — an entry with expires == today is still valid.
#
# The input index.json shape (see FindingsSink.swift):
#   { "totalRuns": N, "rows": [ { "finding": { "hash": "...", ... }, ... } ] }
# Legacy bare-array form is also accepted for compatibility.
set -euo pipefail

INDEX_PATH="${1:-}"
ALLOWLIST_PATH="${2:-$(dirname "$0")/../.github/fuzz-allowlist.json}"

if [[ -z "$INDEX_PATH" ]]; then
    echo "usage: $0 <index.json> [allowlist.json]" >&2
    exit 2
fi

if [[ ! -f "$INDEX_PATH" ]]; then
    # A real campaign ALWAYS writes index.json — FindingsSink.flush() rewrites
    # it on every run, including a clean run with zero findings. So a missing
    # index.json is not "no findings", it is positive evidence the campaign
    # never actually ran: the backend factory can throw before a single
    # iteration executes (e.g. Ollama down / no models pulled), the fuzz CLI
    # still exits 0 in that case (0 runs means isInert is false, so nothing
    # forces a nonzero exit — see ManifoldKit#2367), and a report-then-gate
    # step chain that treats "nothing to report" as "nothing wrong" would
    # rubber-stamp a fuzz job that fuzzed nothing. Fail loud instead.
    echo "fuzz-ci-gate: no index.json at $INDEX_PATH — the campaign did not run (or crashed before writing any output). This is not a clean result; investigate the run that should have produced it." >&2
    exit 1
fi

if [[ ! -f "$ALLOWLIST_PATH" ]]; then
    echo "fuzz-ci-gate: allowlist file not found at $ALLOWLIST_PATH" >&2
    exit 2
fi

# Python does the heavy lifting: parses JSON, compares ISO-8601 dates cleanly,
# and emits a formatted error listing uncovered findings. macOS runners ship
# python3 by default, so no extra install is needed.
python3 - "$INDEX_PATH" "$ALLOWLIST_PATH" <<'PY'
import json
import sys
from datetime import date

index_path, allow_path = sys.argv[1], sys.argv[2]

try:
    with open(index_path, "r", encoding="utf-8") as f:
        index_data = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    print(f"fuzz-ci-gate: failed to parse {index_path}: {e}", file=sys.stderr)
    sys.exit(2)

try:
    with open(allow_path, "r", encoding="utf-8") as f:
        allow_data = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    print(f"fuzz-ci-gate: failed to parse {allow_path}: {e}", file=sys.stderr)
    sys.exit(2)

# Normalise the index to a list of finding dicts. Current envelope wraps rows
# in an object with `totalRuns`; legacy form is a bare array.
if isinstance(index_data, dict) and "rows" in index_data:
    rows = index_data["rows"]
elif isinstance(index_data, list):
    rows = index_data
else:
    print(f"fuzz-ci-gate: unrecognised index.json shape in {index_path}", file=sys.stderr)
    sys.exit(2)

findings = []
for row in rows:
    finding = row.get("finding", row) if isinstance(row, dict) else None
    if not isinstance(finding, dict) or "hash" not in finding:
        continue
    findings.append(finding)

# Build the allowlist map: hash → (expires_date, reason). An invalid date is
# a fatal parse error — fail loudly rather than silently treat the entry as
# expired, which would hide the misconfiguration.
today = date.today()
allow_entries = allow_data.get("allowlist", [])
allow_map = {}
expired_entries = []
for entry in allow_entries:
    h = entry.get("hash")
    expires = entry.get("expires")
    reason = entry.get("reason", "")
    if not h or not expires:
        print(f"fuzz-ci-gate: allowlist entry missing hash or expires: {entry}", file=sys.stderr)
        sys.exit(2)
    try:
        expires_date = date.fromisoformat(expires)
    except ValueError:
        print(f"fuzz-ci-gate: allowlist entry has invalid expires date '{expires}' (use YYYY-MM-DD)", file=sys.stderr)
        sys.exit(2)
    if expires_date < today:
        expired_entries.append((h, expires, reason))
    else:
        allow_map[h] = (expires_date, reason)

# Any allowlist entry whose expires has passed forces a fail — this is the
# "expiring allowlist" mechanism: findings can't be papered over indefinitely,
# a stale entry surfaces in CI and demands triage.
if expired_entries:
    print("fuzz-ci-gate: one or more allowlist entries have expired:", file=sys.stderr)
    for h, expires, reason in expired_entries:
        print(f"  - {h} expired on {expires}: {reason}", file=sys.stderr)
    print("Remove the entry, extend its expiry, or fix the underlying finding.", file=sys.stderr)
    sys.exit(1)

# Any finding not covered by the allowlist fails the job with a formatted
# summary the developer can paste straight into an allowlist entry.
uncovered = []
for f in findings:
    h = f["hash"]
    if h not in allow_map:
        uncovered.append(f)

if uncovered:
    print("fuzz-ci-gate: new fuzz finding(s) not in allowlist:", file=sys.stderr)
    for f in uncovered:
        detector = f.get("detectorId", "?")
        sub = f.get("subCheck", "?")
        severity = f.get("severity", "?")
        model = f.get("modelId", "?")
        trigger = (f.get("trigger") or "")[:120]
        h = f["hash"]
        print(f"  - [{severity}] {detector}/{sub} hash={h} model={model} trigger={trigger!r}", file=sys.stderr)
    print("", file=sys.stderr)
    print("To allowlist (temporarily), add to .github/fuzz-allowlist.json:", file=sys.stderr)
    suggestion = {
        "allowlist": [
            {"hash": f["hash"], "reason": "TODO", "expires": "YYYY-MM-DD"}
            for f in uncovered
        ]
    }
    print(json.dumps(suggestion, indent=2), file=sys.stderr)
    sys.exit(1)

print(f"fuzz-ci-gate: OK ({len(findings)} finding(s), all allowlisted)")
sys.exit(0)
PY
