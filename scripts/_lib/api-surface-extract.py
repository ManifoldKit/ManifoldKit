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

Isolation / Sendable signal (added 2026-07-21, closing the blind spot
recorded in docs/RELEASE-1.0.md Appendix A):
  - Actor-isolation changes on a public symbol (adding/removing `@MainActor`)
    and explicit `Sendable`-conformance changes are source-breaking under
    Swift 6 but were previously invisible to this baseline -- the type-level
    `declKind` line never moved. The raw digester dump DOES carry the signal
    (verified against a real `ManifoldContract` dump, 2026-07-21): a type's
    `conformances` array gains `Sendable` + `SendableMetatype` when isolated
    onto a global actor OR given an explicit `: Sendable`, and `@MainActor`
    additionally sets `declAttributes` to include the digester's generic
    `"Custom"` marker (it does not name which attribute -- "some custom
    attribute is present" is all it says, but that is still a presence
    tripwire, same spirit as the rest of this file).
  - So, for every public `TypeDecl`, two more lines are now emitted when the
    corresponding data is non-empty:
      `<Qualified> conformances: A,B,C`  -- the type's `conformances`,
        sorted, comma-joined, UNFILTERED. Every conformance is kept
        (including universal ones like `Copyable`/`Escapable`) because
        Part 1's contract for this file is "no filtering on conformances",
        and because those universal entries are stable across the whole
        module graph -- they add verbosity, not churn.
      `<Qualified> attrs: X,Y`  -- a FILTERED view of `declAttributes`,
        sorted, comma-joined. Filtering IS load-bearing here, unlike
        conformances -- see ATTR_DENYLIST below for what's excluded and why.
  - ATTR_DENYLIST was chosen empirically, not assumed, against a real dump of
    every DEFAULT_MODULES target (2026-07-21, `scripts/api-surface-baseline.sh`
    treeish, all 29 modules, ~340 declAttributes-bearing nodes at type level).
    Two noise sources were found and confirmed to carry ZERO source-level
    signal for a PR reviewing THIS repo's code:
      1. `OriginallyDefinedIn`, `TypeEraser`, `EagerMove`, `Frozen`: observed
         ONLY on `TypeDecl` nodes with `"isExternal": true` (this module's
         retroactive extension of a type declared in ANOTHER module -- e.g.
         `extension EnvironmentValues { ... }` for a SwiftUI environment key,
         or `extension Array` for a `ContiguousBytes` conformance). These are
         the FRAMEWORK's own attributes on ITS type, bleeding through the
         extension node -- not a decision made in this codebase, and stable
         across PRs (only an SDK bump moves them, an unrelated event this
         file already treats as an accepted, separately-documented source of
         drift -- see the ManifoldFoundation SDK note in
         scripts/api-surface-baseline.sh). Confirmed: every occurrence of
         these four across the full dump was on an isExternal node
         (`EnvironmentValues`, `View`, `Array`, `AsyncSequence`); none on a
         type this repo declares.
      2. `Preconcurrency`: observed on effectively every SwiftUI `View`-
         conforming struct this repo declares (55 type-level occurrences, all
         `isExternal: false`) -- it is attached automatically by the compiler
         to a type adopting an externally-declared protocol whose requirements
         cross a concurrency domain, not a `@preconcurrency` attribute anyone
         in this codebase wrote. It fires on essentially every View file
         regardless of any deliberate isolation choice, so keeping it would
         add constant, non-actionable churn without ever isolating a real
         review-worthy change.
    `Available` (`@available(...)`) was DELIBERATELY KEPT despite also
    appearing on isExternal nodes (the same `EnvironmentValues`/`AsyncSequence`
    bleed-through as above): unlike the four denylisted above, it ALSO
    appears on types this repo genuinely declares and gates on purpose
    (`ManifoldFoundation.FoundationBackend`'s iOS/macOS 26 gate,
    every `ManifoldAppIntents` type's OS-version gate) -- excluding it would
    hide a real, source-controlled availability change. `Final`, `ObjC`,
    `Indirect`, and `Custom` were kept for the same reason: each was verified
    to appear only on genuinely-ours declarations (`final class`, `@objc`,
    `indirect enum`) or to BE the signal this section exists to surface
    (`Custom`).
  - Member-level declAttributes (e.g. `@MainActor` on one public method
    rather than the whole type) are NOT emitted -- checked empirically and
    found too noisy to be worth it. The same dump shows member-level `Custom`
    alone at ~1024 occurrences (vs. 135 at type level) because the digester's
    generic marker doesn't distinguish `@MainActor` from `@escaping`,
    `@ViewBuilder`, property wrappers, or any other custom attribute a member
    might carry -- emitting it would multiply the line count roughly 8x
    across every baseline file for no gain in what the marker can actually
    tell a reviewer. Compiler-synthesized member bookkeeping
    (`HasStorage`/`HasInitialValue`/`Implements`/`Semantics`) makes the
    member-level noise floor even higher (2000+ occurrences each). Type-level
    is the accepted minimum; a member-level `nonisolated`/`@MainActor` change
    on an otherwise-unisolated type remains a manual review item, same as the
    original Appendix A scope but narrower.
  - Two further residual edges, accepted with eyes open (review 2026-07-21):
      1. Denylisting `Preconcurrency` also hides an AUTHORED `@preconcurrency`
         change on a type this repo declares, not only the compiler-inferred
         View noise -- the marker is name-based and cannot tell the two
         apart. Accepted because the 55 inferred occurrences would bury the
         rare authored one; a deliberate `@preconcurrency` change on a public
         type is a manual review item.
      2. Removal asymmetry: `@MainActor` REMOVAL registers only via the
         `Custom` attr flipping off or the implicit `Sendable`/
         `SendableMetatype` conformances leaving. A type that is
         Sendable-by-members anyway AND carries a second Custom-marked
         attribute (e.g. a property wrapper) changes neither line when
         `@MainActor` is removed -- a narrow, compound edge, also a manual
         review item.

Deliberately coarse (a presence tripwire, not a full ABI differ -- see
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

# See the "Isolation / Sendable signal" section of the module docstring above
# for the empirical evidence behind each entry -- chosen against a real dump
# of every scripts/api-surface-baseline.sh module (2026-07-21), not assumed.
ATTR_DENYLIST = {
    # Framework-owned attributes that bleed through this module's retroactive
    # extension of a type declared elsewhere (isExternal nodes only, e.g.
    # `extension EnvironmentValues`/`extension Array`) -- not a decision made
    # in this codebase, and stable across PRs (only an SDK bump moves them).
    "OriginallyDefinedIn",
    "TypeEraser",
    "EagerMove",
    "Frozen",
    # Compiler-inferred bookkeeping attached to nearly every SwiftUI `View`-
    # conforming struct this repo declares, regardless of any deliberate
    # isolation choice -- constant churn, never signal.
    "Preconcurrency",
}


def is_non_public(node):
    """True for package-scoped (`isInternal`) and `@_spi` (`spi_group_names`)
    declarations -- neither is part of the public consumer contract."""
    return bool(node.get("isInternal")) or bool(node.get("spi_group_names"))


def conformance_names(node):
    """Sorted, de-duplicated conformance names for a TypeDecl node.
    UNFILTERED -- see the module docstring for why (conformances are stable
    boilerplate, not a source of PR-to-PR noise)."""
    names = set()
    for conformance in node.get("conformances", []) or []:
        name = conformance.get("printedName") or conformance.get("name")
        if name:
            names.add(name)
    return sorted(names)


def filtered_attr_names(node):
    """Sorted, de-duplicated declAttributes for a TypeDecl node, with
    ATTR_DENYLIST removed. FILTERED -- unlike conformances, this list is the
    load-bearing part of the isolation-signal fix; see the module docstring
    for the empirical basis of ATTR_DENYLIST."""
    attrs = {a for a in (node.get("declAttributes") or []) if a not in ATTR_DENYLIST}
    return sorted(attrs)


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
            conformances = conformance_names(child)
            if conformances:
                lines.add(f"{qualified} conformances: {','.join(conformances)}")
            attrs = filtered_attr_names(child)
            if attrs:
                lines.add(f"{qualified} attrs: {','.join(attrs)}")
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
