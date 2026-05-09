#!/usr/bin/env bash
#
# generate-sbom.sh — emit a CycloneDX 1.5 SBOM for the ManifoldKit Swift package.
#
# Why this lives as a hand-rolled converter rather than `cyclonedx-bom` /
# `swift-sbom-action`:
#
#   * Swift Package Manager's only machine-readable dependency surface is
#     `swift package show-dependencies --format json` (recursive tree of
#     `{identity, name, url, version, dependencies}`) plus `Package.resolved`
#     (the flat pin list with revisions). Existing CycloneDX generators target
#     npm/pip/maven and don't consume either of these natively.
#
#   * The conversion is small and deterministic: every dep has a name, URL,
#     and pinned revision (from Package.resolved). We emit one CycloneDX
#     `component` per pin, with the resolved git revision as the `version`
#     when the pin is by-revision, and the SemVer when the pin is by-version.
#
# The output is `sbom.cdx.json` in the working directory by default; pass
# `--output PATH` to redirect.
#
# Schema: https://cyclonedx.org/docs/1.5/json/
# Validated against: https://github.com/CycloneDX/specification/raw/master/schema/bom-1.5.schema.json

set -euo pipefail

OUTPUT="${PWD}/sbom.cdx.json"
PACKAGE_PATH="${PWD}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --package-path) PACKAGE_PATH="$2"; shift 2 ;;
        -h|--help)
            cat <<USAGE
Usage: generate-sbom.sh [--output PATH] [--package-path DIR]

Emits a CycloneDX 1.5 JSON SBOM enumerating every Swift package dependency
listed in Package.resolved. Output defaults to ./sbom.cdx.json.
USAGE
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

cd "$PACKAGE_PATH"

if [[ ! -f Package.resolved ]]; then
    echo "error: Package.resolved not found in $PACKAGE_PATH" >&2
    echo "run 'swift package resolve' first" >&2
    exit 1
fi

# Read the package version from version.txt (Release Please owns it).
PACKAGE_VERSION="unknown"
if [[ -f version.txt ]]; then
    PACKAGE_VERSION="$(cat version.txt | tr -d '[:space:]')"
fi

# Prefer git rev-parse; fall back to env var supplied by the runner.
GIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERIAL_UUID="urn:uuid:$(uuidgen | tr '[:upper:]' '[:lower:]')"

python3 - "$OUTPUT" "$PACKAGE_VERSION" "$GIT_SHA" "$TIMESTAMP" "$SERIAL_UUID" <<'PY'
import json
import sys
from pathlib import Path

output, package_version, git_sha, timestamp, serial_uuid = sys.argv[1:6]

resolved = json.loads(Path("Package.resolved").read_text())
pins = resolved.get("pins", [])

components = []
for pin in pins:
    identity = pin.get("identity", "")
    location = pin.get("location", "")
    state = pin.get("state", {}) or {}
    revision = state.get("revision", "")
    version = state.get("version") or revision[:12] or "unknown"

    # CycloneDX `bom-ref` must be unique within the document.
    bom_ref = f"pkg:swift/{identity}@{version}"

    component = {
        "type": "library",
        "bom-ref": bom_ref,
        "name": identity,
        "version": version,
        "purl": bom_ref,
        "externalReferences": [],
    }

    if location:
        component["externalReferences"].append({
            "type": "vcs",
            "url": location,
        })

    if revision:
        # CycloneDX "hashes" requires algorithm names from a fixed list; git
        # SHA-1 commit IDs aren't a standard SBOM hash. Surface as a property
        # instead so consumers can audit which exact upstream revision shipped.
        component["properties"] = [
            {"name": "swift:git-revision", "value": revision},
        ]

    components.append(component)

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": serial_uuid,
    "version": 1,
    "metadata": {
        "timestamp": timestamp,
        "tools": [
            {
                "vendor": "ManifoldKit",
                "name": "scripts/generate-sbom.sh",
                "version": "1.0.0",
            }
        ],
        "component": {
            "type": "library",
            "bom-ref": f"pkg:swift/ManifoldKit@{package_version}",
            "name": "ManifoldKit",
            "version": package_version,
            "purl": f"pkg:swift/ManifoldKit@{package_version}",
            "properties": [
                {"name": "vcs:git-revision", "value": git_sha},
            ],
        },
    },
    "components": components,
}

Path(output).write_text(json.dumps(bom, indent=2, sort_keys=True) + "\n")
print(f"wrote {len(components)} components to {output}")
PY
