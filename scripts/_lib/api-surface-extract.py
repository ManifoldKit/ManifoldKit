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

Access-level filtering (markers verified against a raw ManifoldContract
dump, 2026-07-06):
  - Nodes marked `"isInternal": true` are `package`-scoped declarations
    (e.g. `package final class SSEEventIDTracker`). The digester includes
    them in the dump, but they are NOT public API -- excluded here, whole
    subtree. This also makes a public->package DEMOTION visible: the
    symbol's lines leave the baseline and --check reports them as removed.
  - Nodes carrying `"spi_group_names"` are `@_spi(...)` declarations
    (e.g. `@_spi(BackendInternals) HeuristicTokenizer`). SPI is not the
    public consumer contract either -- excluded, whole subtree. The
    BackendInternals seam has its own compile-time freeze
    (Tests/APIFreezeTests/BackendSeamTests.swift), so it is not
    unguarded, just out of scope for THIS baseline.
  - Nodes marked `"isExternal": true` are types declared in ANOTHER module
    but extended in this one (e.g. `extension Array` / retroactive
    conformances). KEPT: the extension members are this module's public
    API contribution.

Deliberately coarse (this is the 0.2b prototype -- see
scripts/api-surface-baseline.sh for the full mechanism writeup):
  - Uses `printedName` (the full parameter-label signature) rather than the
    bare `name`, so a parameter ADDED to an existing initializer (the
    GenerationConfig 28-param accretion pattern that motivated this
    tripwire) shows up as one line removed + one line added, not silence.
  - Does not descend into a member's own children (its parameter/return
    TypeNominal nodes) -- only one level of member-ness per type. So a
    member's TYPE changing (property type, param/return type, enum-case
    payload) is INVISIBLE to this baseline; the existing per-PR
    breakage-diff gate owns that class of change. See the "division of
    labor" section in scripts/api-surface-baseline.sh.
  - Duplicate signatures within a type (observed for some protocol-extension
    methods that also get a concrete override) collapse to one line via a
    `set` -- this is a coarse presence check, not a full ABI diff.
"""
import json
import sys


def is_non_public(node):
    """True for package-scoped (`isInternal`) and `@_spi` (`spi_group_names`)
    declarations -- neither is part of the public consumer contract."""
    return bool(node.get("isInternal")) or bool(node.get("spi_group_names"))


def emit_lines(node, prefix, lines):
    """node: a TypeDecl-shaped dict (or the Root). prefix: qualified name
    accumulated so far ('' at the root)."""
    for child in node.get("children", []):
        kind = child.get("kind")
        if kind == "Import":
            continue
        if is_non_public(child):
            # Skip the whole subtree: a package/SPI type's members are not
            # public either, and a public->package demotion must read as
            # the entire symbol (plus members) leaving the baseline.
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
