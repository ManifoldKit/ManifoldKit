#!/usr/bin/env python3
"""Compute a deterministic public-type-coverage table for the M0 demo-coverage
scoreboard (issue #2453) — one signal feeding `scripts/demo-coverage.sh`.

The question this answers: of every public type ManifoldKit ships (per module,
as recorded in the api-surface baseline `scripts/api-surface-baseline.sh`
already maintains for the API-freeze gate), how many are ever *named* by an
identifier somewhere under `Example/**/*.swift`? A type nobody's example code
ever spells is a type no demo vehicle can be proving works.

Follows the style of `scripts/_lib/api-surface-extract.py`: pure stdlib, no
timestamps, no randomness, stable sort, deterministic output for a given tree.

## Fail-closed, on purpose

This is a scoreboard input feeding a report a milestone is measured by — a
silent "everything's fine, 0/0" on a broken input is worse than no number at
all, because it reads as real data. Every failure mode below exits non-zero
with a named error on stderr instead of degrading quietly:

  (a) the api-surface-baseline directory is missing
  (b) the api-surface-baseline directory exists but contains zero `.txt` files
  (c) the Example root directory is missing
  (d) zero identifiers were collected from Example/**/*.swift (an empty tree,
      or every file failed to read)
  (e) any `.txt` baseline file or `.swift` Example file could not be opened
      (permissions, a symlink race, etc.) — no `except OSError: continue`
  (f) a baseline line that isn't a `conformances:`/`attrs:` line and doesn't
      parse into `<qualified-name> <declKind>` (i.e. has no space at all)

NOTE for `scripts/demo-coverage.sh` callers: `--check` never invokes this
script — it scores R1/R2/R3 entirely from `current_state`, which reads only
the manifest. Only the scoreboard (default output, or `--markdown`) calls
this, and it now propagates a non-zero exit via command substitution + `set
-e` rather than a discarded process substitution (verified: a process
substitution's exit status is NOT checked by `set -e` on its own).

## Inputs

- `Tests/APIFreezeTests/api-surface-baseline/*.txt` — one file per module,
  produced by `api-surface-extract.py`. Each line is either:
    `<Qualified> <declKind>`                          (a type declaration)
    `<Qualified> conformances: A,B,C`                  (skipped — see below)
    `<Qualified> attrs: X,Y`                            (skipped — see below)
    `<Owner>.<signature> <declKind>`                   (a member)
  where `<Owner>` is `(top-level)` for a free function/typealias/var declared
  directly under the module (see api-surface-extract.py's docstring).
- `Example/**/*.swift` — every Swift source file under the Example apps.

## "Type" extraction

Per module, for every non-conformances/non-attrs line: split off the trailing
decl-kind token (the last whitespace-separated token — decl kinds are single
words: `Struct`, `Class`, `Constructor`, `Func`, …, matching how
`api-surface-extract.py` emits them, so this split is safe). What remains is
the qualified name. The **type** for that line is its first dotted component:
`BackendCapabilities.init(...)` -> `BackendCapabilities`; a nested-type
declaration line `Outer.Inner` -> `Outer`; a bare type declaration line with
no dot (`BackendCapabilities`) -> itself; a top-level free function
(`(top-level).someFunc(_:)`) -> `(top-level)` (kept as its own pseudo-type
bucket — free functions have no type identity to search for, so this bucket
is always uncovered by construction; that is accepted, not a bug).

`types_total` for a module is the count of distinct type buckets found this
way. `types_named_in_examples` is how many of those bucket names appear as a
whole-word identifier somewhere in the concatenated Example source (the
literal string `(top-level)` can never match an identifier regex, so that
bucket never counts as named — consistent with it having no name to spell).

## Output

One TSV line per module (sorted by module name), then a `TOTAL` line:

    <Module>\t<types_total>\t<types_named_in_examples>
    ...
    TOTAL\t<sum_types_total>\t<sum_types_named_in_examples>

No header row — `scripts/demo-coverage.sh` parses this directly. Modules with
zero extracted types are still emitted (0\t0) so the per-module table is
complete, not silently sparse.
"""
import os
import re
import sys

IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class FatalInputError(Exception):
    """Raised for any input defect this tool must fail closed on."""


def module_types(baseline_path):
    """Return the set of distinct type-bucket names for one baseline file.
    Raises FatalInputError on an unreadable file or a line that doesn't parse."""
    types = set()
    try:
        with open(baseline_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as exc:
        raise FatalInputError(f"cannot read baseline file {baseline_path}: {exc}") from exc

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\n")
        if not line:
            continue
        if " conformances: " in line or " attrs: " in line:
            continue
        # Split off the trailing decl-kind token (single word, no spaces).
        parts = line.rsplit(" ", 1)
        if len(parts) != 2:
            raise FatalInputError(
                f"{baseline_path}:{line_number}: does not parse as "
                f"'<qualified-name> <declKind>' (no space found): {line!r}"
            )
        qualified = parts[0]
        if "." in qualified:
            type_name = qualified.split(".", 1)[0]
        else:
            type_name = qualified
        types.add(type_name)
    return types


def collect_example_identifiers(example_root):
    """Return the set of every identifier token across Example/**/*.swift.
    Raises FatalInputError on any unreadable .swift file."""
    identifiers = set()
    for dirpath, _dirnames, filenames in os.walk(example_root):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError as exc:
                raise FatalInputError(f"cannot read Example source file {path}: {exc}") from exc
            identifiers.update(IDENTIFIER_RE.findall(content))
    return identifiers


def run(baseline_dir, example_root):
    """Returns the rows/totals, or raises FatalInputError. Separated from
    main() so a caller (or a test) can assert on the exception directly."""
    if not os.path.isdir(baseline_dir):
        raise FatalInputError(f"api-surface-baseline directory does not exist: {baseline_dir}")
    if not os.path.isdir(example_root):
        raise FatalInputError(f"Example root directory does not exist: {example_root}")

    module_files = sorted(name for name in os.listdir(baseline_dir) if name.endswith(".txt"))
    if not module_files:
        raise FatalInputError(f"api-surface-baseline directory contains zero .txt files: {baseline_dir}")

    example_identifiers = collect_example_identifiers(example_root)
    if not example_identifiers:
        raise FatalInputError(
            f"zero identifiers collected from {example_root}/**/*.swift "
            "(empty tree, or no .swift files found)"
        )

    total_types = 0
    total_named = 0
    rows = []
    for name in module_files:
        module_name = name[: -len(".txt")]
        types = module_types(os.path.join(baseline_dir, name))
        named = sum(1 for t in types if t != "(top-level)" and t in example_identifiers)
        rows.append((module_name, len(types), named))
        total_types += len(types)
        total_named += named

    return rows, total_types, total_named


def main():
    if len(sys.argv) != 3:
        print(
            "usage: demo-coverage-types.py <api-surface-baseline-dir> <example-root>",
            file=sys.stderr,
        )
        sys.exit(2)
    baseline_dir = sys.argv[1]
    example_root = sys.argv[2]

    try:
        rows, total_types, total_named = run(baseline_dir, example_root)
    except FatalInputError as exc:
        print(f"demo-coverage-types.py: {exc}", file=sys.stderr)
        sys.exit(1)

    for module_name, types_total, types_named in rows:
        print(f"{module_name}\t{types_total}\t{types_named}")
    print(f"TOTAL\t{total_types}\t{total_named}")


if __name__ == "__main__":
    main()
