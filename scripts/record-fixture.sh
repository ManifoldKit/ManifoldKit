#!/usr/bin/env bash
#
# record-fixture.sh — capture a backend SSE/NDJSON response with redaction.
#
# Usage:
#   scripts/record-fixture.sh <output-path> < input-stream
#
# Reads an SSE or NDJSON byte stream on stdin, applies the redaction filter
# documented in Tests/Fixtures/REDACTION_POLICY.md line-by-line, and writes
# the scrubbed result to <output-path>.
#
# Typical pipeline:
#   curl -N -H "Authorization: Bearer $OPENAI_API_KEY" \
#        -d @request.json https://api.openai.com/v1/chat/completions \
#     | scripts/record-fixture.sh Tests/Fixtures/backends/openai/tool-calls/<scenario>.sse
#
# Why this is a script rather than a Swift test fixture loader:
# - Keeps credentials out of test-runner memory (the script never sees the
#   raw key, only the live HTTP body).
# - Lets a developer replay-record a fixture without booting the whole
#   ManifoldKit test target.
# - Mirrors the audit regex in FixtureRedactionAuditTest so a recording
#   that passes the script also passes CI.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <output-path>" >&2
    exit 2
fi

OUTPUT_PATH="$1"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"

# sed pipeline — order matters: redact bearer/key patterns before the IPv4
# pass so a key fragment that happens to contain dotted-decimal does not get
# half-rewritten.
#
# `LC_ALL=C` keeps the regex byte-oriented; sed on macOS otherwise interprets
# UTF-8 differently from sed on Linux CI runners.
LC_ALL=C sed -E \
    -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-REDACTED/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/sk-REDACTED/g' \
    -e 's/org-[A-Za-z0-9]+/org-REDACTED/g' \
    -e 's/Bearer [A-Za-z0-9._-]+/Bearer REDACTED/g' \
    -e 's/"(account_id|account_uuid|customer_id)"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"/"\1":"00000000-0000-0000-0000-000000000000"/g' \
    -e 's/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/user@example.com/g' \
    > "$OUTPUT_PATH"

echo "Wrote redacted fixture to $OUTPUT_PATH" >&2
echo "Re-run FixtureRedactionAuditTest after committing to confirm the audit passes." >&2
