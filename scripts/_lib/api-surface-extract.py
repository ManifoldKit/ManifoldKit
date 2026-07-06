#!/usr/bin/env python3
"""Normalize a `swift package diagnose-api-breaking-changes --baseline-dir`
JSON dump (ABIRoot format, produced by swift-api-digester) into a flat,
deterministic text baseline: one line per public member.

Line shape: `<Owner>.<signature> <declKind>`, e.g.:
    BackendCapabilities.init(supportedParameters:maxContextTokens:...) Constructor
    BackendCapabilities.supportsVision Var

Top-level (non-nested-type) declarations use `(top-level)` as the owner:
    (top-level).someFreeFunction(_:) Func

The type declaration itself also gets a line (so a type ADDED, REMOVED, or
changed in kind -- e.g. struct -> class -- is visible even with zero member
changes):
    BackendCapabilities Struct

Nested types (e.g. an enum nested inside a struct) are walked recursively
and get their own dotted qualified name (`Outer.Inner`); their members are
attributed to the nested type, not the enclosing one.

Deliberately coarse (this is the 0.2b prototype -- see
scripts/api-surface-baseline.sh for the full mechanism writeup):
  - Uses `printedName` (the full parameter-label signature) rather than the
    bare `name`, so a parameter ADDED to an existing initializer (the
    GenerationConfig 28-param accretion pattern that motivated this
    tripwire) shows up as one line removed + one line added, not silence.
  - Does not descend into a member's own children (its parameter/return
    TypeNominal nodes) -- only one level of member-ness per type.
  - Duplicate signatures within a type (observed for some protocol-extension
    methods that also get a concrete override) collapse to one line via a
    `set` -- this is a coarse presence check, not a full ABI diff.
"""
import json
import sys


def emit_lines(node, prefix, lines):
    """node: a TypeDecl-shaped dict (or the Root). prefix: qualified name
    accumulated so far ('' at the root)."""
    for child in node.get("children", []):
        kind = child.get("kind")
        if kind == "Import":
            continue
        if kind == "TypeDecl":
            name = child.get("name", "<unnamed>")
            qualified = f"{prefix}.{name}" if prefix else name
            decl_kind = child.get("declKind", kind)
            lines.add(f"{qualified} {decl_kind}")
            emit_lines(child, qualified, lines)
        else:
            # A member of the enclosing type (or a top-level free function /
            # typealias when prefix == '', i.e. a direct child of Root).
            signature = child.get("printedName", child.get("name", "<unnamed>"))
            decl_kind = child.get("declKind", kind)
            owner = prefix if prefix else "(top-level)"
            lines.add(f"{owner}.{signature} {decl_kind}")


def main():
    if len(sys.argv) != 2:
        print("usage: api-surface-extract.py <digester-dump.json>", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        data = json.load(f)
    root = data["ABIRoot"]
    lines = set()
    emit_lines(root, "", lines)
    for line in sorted(lines):
        print(line)


if __name__ == "__main__":
    main()
