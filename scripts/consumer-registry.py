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


def load(path):
    rows = json.loads(path.read_text())
    if not isinstance(rows, list) or not rows:
        raise ValueError("consumer registry must be a nonempty array")
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"repo", "pin", "bump_branch", "bump_match"}:
            raise ValueError("consumer row must contain repo, pin, bump_branch, bump_match")
        if not all(isinstance(value, str) for value in row.values()):
            raise ValueError("consumer fields must be strings")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", row["repo"]):
            raise ValueError("invalid consumer repository")
        if row["repo"] in seen:
            raise ValueError("duplicate consumer: " + row["repo"])
        seen.add(row["repo"])
        if row["pin"] not in {"minor", "exact"} or row["bump_match"] not in {"exact", "prefix"}:
            raise ValueError("invalid pin or bump match policy")
        if not re.fullmatch(r"[a-zA-Z0-9_/-]+", row["bump_branch"]):
            raise ValueError("invalid bump branch")
    return rows


def table(rows):
    lines = [START, "| Consumer | Core pin | Bump branch |", "|---|---|---|"]
    for row in rows:
        pin = "exact release" if row["pin"] == "exact" else "current minor"
        suffix = "*" if row["bump_match"] == "prefix" else ""
        lines.append(f'| `{row["repo"]}` | {pin} | `{row["bump_branch"]}{suffix}` |')
    return "\n".join(lines + [END])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=ROOT / "scripts/consumer-registry.json")
    parser.add_argument("mode", choices=["repos", "rows", "matrix", "docs", "check"])
    args = parser.parse_args()
    try:
        rows = load(args.registry)
        if args.mode == "repos":
            print("\n".join(row["repo"] for row in rows))
        elif args.mode == "rows":
            print("\n".join("\t".join(row[key] for key in ("repo", "pin", "bump_branch", "bump_match")) for row in rows))
        elif args.mode == "matrix":
            print(json.dumps({"companion": [row["repo"] for row in rows]}, separators=(",", ":")))
        elif args.mode == "docs":
            print(table(rows))
        else:
            doc = (ROOT / "docs/COMPANION-BACKENDS.md").read_text()
            if doc.count(START) != 1 or doc.count(END) != 1 or table(rows) not in doc:
                raise ValueError("consumer documentation drift; regenerate with consumer-registry.py docs")
            print(f"Consumer registry and documentation agree ({len(rows)} consumers).")
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
