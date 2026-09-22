#!/usr/bin/env python3
"""Validated release consumers; stdout is machine-readable, errors fail closed."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
START = "<!-- consumer-registry:start -->"
END = "<!-- consumer-registry:end -->"
PACKAGE_KEYS = {"kind", "repo", "pin", "bump_branch", "bump_match"}
APP_KEYS = {"kind", "repo", "workflow", "event_type", "artifact_prefix"}


def load(path):
    rows = json.loads(path.read_text())
    if not isinstance(rows, list) or not rows:
        raise ValueError("consumer registry must be a nonempty array")
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("consumer row must be an object")
        kind = row.get("kind")
        expected_keys = PACKAGE_KEYS if kind == "swift-package" else APP_KEYS if kind == "app-canary" else None
        if expected_keys is None or set(row) != expected_keys:
            raise ValueError("consumer row must match the swift-package or app-canary schema")
        if not all(isinstance(value, str) for value in row.values()):
            raise ValueError("consumer fields must be strings")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", row["repo"]):
            raise ValueError("invalid consumer repository")
        if row["repo"] in seen:
            raise ValueError("duplicate consumer: " + row["repo"])
        seen.add(row["repo"])
        if kind == "swift-package":
            if row["pin"] not in {"minor", "exact"} or row["bump_match"] not in {"exact", "prefix"}:
                raise ValueError("invalid pin or bump match policy")
            if not re.fullmatch(r"[a-zA-Z0-9_/-]+", row["bump_branch"]):
                raise ValueError("invalid bump branch")
        else:
            if not re.fullmatch(r"[a-zA-Z0-9_.-]+\.yml", row["workflow"]):
                raise ValueError("invalid app workflow")
            if not re.fullmatch(r"[a-z][a-z0-9-]*", row["event_type"]):
                raise ValueError("invalid app dispatch event type")
            if not re.fullmatch(r"[a-zA-Z0-9_.-]+-", row["artifact_prefix"]):
                raise ValueError("invalid app artifact prefix")
    return rows


def table(rows):
    lines = [START, "| Consumer | Kind | Core pin | Bump branch / canary |", "|---|---|---|---|"]
    for row in rows:
        if row["kind"] == "swift-package":
            pin = "exact release" if row["pin"] == "exact" else "current minor"
            suffix = "*" if row["bump_match"] == "prefix" else ""
            details = f'`{row["bump_branch"]}{suffix}`'
        else:
            pin = "exact dispatched commit"
            details = f'`{row["workflow"]}` / `{row["event_type"]}`'
        lines.append(f'| `{row["repo"]}` | {row["kind"]} | {pin} | {details} |')
    return "\n".join(lines + [END])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=ROOT / "scripts/consumer-registry.json")
    parser.add_argument("mode", choices=["repos", "rows", "matrix", "app-rows", "docs", "check"])
    args = parser.parse_args()
    try:
        rows = load(args.registry)
        packages = [row for row in rows if row["kind"] == "swift-package"]
        apps = [row for row in rows if row["kind"] == "app-canary"]
        if args.mode == "repos":
            print("\n".join(row["repo"] for row in packages))
        elif args.mode == "rows":
            print("\n".join("\t".join(row[key] for key in ("repo", "pin", "bump_branch", "bump_match")) for row in packages))
        elif args.mode == "matrix":
            print(json.dumps({"companion": [row["repo"] for row in packages]}, separators=(",", ":")))
        elif args.mode == "app-rows":
            print("\n".join("\t".join(row[key] for key in ("repo", "workflow", "event_type", "artifact_prefix")) for row in apps))
        elif args.mode == "docs":
            print(table(rows))
        else:
            doc = (ROOT / "docs/COMPANION-BACKENDS.md").read_text()
            if doc.count(START) != 1 or doc.count(END) != 1 or table(rows) not in doc:
                raise ValueError("consumer documentation drift; regenerate with consumer-registry.py docs")
            print(f"Consumer registry and documentation agree ({len(packages)} packages, {len(apps)} apps).")
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
