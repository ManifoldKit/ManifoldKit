#!/usr/bin/env bash
# Dispatch every registered Swift-package consumer, aggregating failures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${TAG_NAME:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: TAG_NAME and GH_TOKEN are required for core-release dispatch." >&2
    exit 2
fi
consumers=$(python3 "$ROOT/scripts/consumer-registry.py" repos)
failed=""
for repo in $consumers; do
    if gh api -X POST "repos/ManifoldKit/${repo}/dispatches" \
        -f event_type=core-release -f "client_payload[tag]=${TAG_NAME}"; then
        echo "PASS: dispatched core-release (${TAG_NAME}) to ${repo}"
    else
        echo "ERROR: could not dispatch core-release to ${repo}" >&2
        failed="${failed} ${repo}"
    fi
done
if [ -n "$failed" ]; then
    echo "ERROR: core-release dispatch failed for:${failed}" >&2
    exit 1
fi
echo "All registered Swift-package consumers dispatched for ${TAG_NAME}."
