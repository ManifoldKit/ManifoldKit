#!/bin/bash
# lint-doc-claims.sh — cheap PR-time mirror of the markdown-only checks in
# Tests/ManifoldCoreTests/DocClaimsAuditTest.swift.
#
# WHY THIS EXISTS (not just what it checks): ci.yml's macOS `test` job (which
# runs the authoritative Swift audit) is paths-filtered and does NOT include
# `docs/**` or `**/*.md`, and scripts/affected-suites.sh deliberately keeps the
# affected-suite set empty for docs-only diffs ("NONE stays NONE"). So a
# docs-only PR never runs the audit on the PR head — the "CI Required Test
# Shim" reports green in its place. The merge queue's `merge_group` trigger has
# no paths filter and forces a full run, so a docs-only PR with a broken link
# discovers it for the first time *inside the queue*, where it also poisons the
# batch of up to 5 PRs validated together (PR #2306 did exactly this to PR
# #2212 six times in 2026-07). Lint is ubuntu-latest, unconditional, and
# already runs on docs-only PRs, so this is where the check belongs.
#
# This is the same problem, and the same remedy, as scripts/lint-docs-headers.sh
# — written after an adversarial review pointed out that DocClaimsAuditTest
# shipped with the identical shape and no mirror.
#
# ── SCOPE: three of the four checks, on purpose ────────────────────────────
# Mirrored here (markdown-only, so a docs-only diff can break them):
#   1. relative `.md` links resolve on disk
#   2. `file.md#anchor` resolves to a real heading (GitHub slug rules)
#   3. no `docs/*.md` is unreachable from every other Markdown file
#
# NOT mirrored: the symbol-existence check. It needs the Swift token index, is
# the most intricate part of the audit, and would be the likeliest to drift.
# It is also the one check a docs-only diff cannot newly break — it breaks when
# *sources* change, and a source change always triggers ci.yml, where the
# authoritative Swift audit runs. Mirroring it would buy coverage that already
# exists at the cost of the drift risk.
#
# ── DRIFT GUARD ────────────────────────────────────────────────────────────
# Tests/ManifoldCoreTests/DocClaimsAuditTest.swift is AUTHORITATIVE for the
# RULES. Both run on a normal source PR, so a rule disagreement surfaces as one
# passing and the other failing rather than as silence. When you change a rule
# in the Swift audit, change it here in the same commit.
#
# Two known CORPUS divergences where this script is deliberately STRICTER — if
# it fails and the Swift audit passes, check these before assuming the script is
# stale:
#   1. Hidden paths. Swift's enumerator passes `.skipsHiddenFiles`; python's
#      os.walk does not, so a doc under `docs/.something/` is checked here only.
#   2. A link target that is a *directory* named `foo.md`. Swift uses
#      `fileExists` (true for directories); python uses `os.path.isfile`.
# Both are contrived, neither occurs in the repo today, and stricter is the
# right direction — but "the Swift audit is right" would send you the wrong way.
#
# Exit codes: 0 clean; 1 violations found or corpus not located.
#
# Portability: bash 3.2 + python3 (ubuntu-latest and macOS both have both).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "${REPO_ROOT}/docs" ]]; then
    echo "::error::docs/ not found at ${REPO_ROOT}/docs"
    exit 1
fi

echo "── doc-claims-lint: relative links, anchors, index coverage ──────────"

python3 - "$REPO_ROOT" <<'PYEOF'
import os, re, sys

repo = sys.argv[1]

def corpus():
    """Root-level *.md, docs/** and every DocC article — mirrors markdownFiles()."""
    files = []
    for name in sorted(os.listdir(repo)):
        if name.endswith(".md") and os.path.isfile(os.path.join(repo, name)):
            files.append(os.path.join(repo, name))
    for sub in ("docs", "Sources"):
        base = os.path.join(repo, sub)
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in sorted(filenames):
                if fn.endswith(".md"):
                    files.append(os.path.join(dirpath, fn))
    return files

def read(path):
    with open(path, encoding="utf-8", errors="ignore") as handle:
        return handle.read()

def github_slug(heading):
    lowered = heading.strip().lower()
    stripped = "".join(
        ch for ch in lowered
        if ch.isalnum() or ch.isspace() or ch in "-_"
    )
    return stripped.replace(" ", "-")

def heading_slugs(path):
    """Fence-aware: `# comment` inside a ``` block is not a heading."""
    slugs = {}
    fence = None
    for line in read(path).split("\n"):
        trimmed = line.strip()
        if fence:
            if trimmed.startswith(fence):
                fence = None
            continue
        if trimmed.startswith("```"):
            fence = "```"; continue
        if trimmed.startswith("~~~"):
            fence = "~~~"; continue
        match = re.match(r"#{1,6}\s+(.*)$", line)
        if not match:
            continue
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", match.group(1))
        text = re.sub(r"[`*]", "", text)
        slug = github_slug(text)
        slugs[slug] = slugs.get(slug, 0) + 1
    return slugs

def local_md(target):
    path = target.split("#", 1)[0]
    if not path or "://" in path or path.startswith("mailto:"):
        return None
    return path if path.lower().endswith(".md") else None

files = corpus()
if len(files) < 90:
    print(f"::error::Only {len(files)} Markdown files found — corpus did not resolve; every check below would vacuously pass")
    sys.exit(1)

# Per-directory floor, mirroring the Swift audit's. docs/ supplies 71 of the 151
# corpus files, so the aggregate floor above stops catching a vanished docs/ once
# the DocC catalogs grow past ~80 files. All three checks below read docs/
# specifically, so assert on it directly rather than inferring it from the total.
docs_top = [
    n for n in os.listdir(os.path.join(repo, "docs"))
    if n.endswith(".md") and os.path.isfile(os.path.join(repo, "docs", n))
]
if len(docs_top) < 40:
    print(f"::error::Only {len(docs_top)} docs/*.md found — the link, anchor and orphan checks would vacuously pass")
    sys.exit(1)

violations = []
anchor_cache = {}

for path in files:
    rel = os.path.relpath(path, repo)
    base = os.path.dirname(path)
    for target in re.findall(r"\]\(([^)\s]+)\)", read(path)):
        local = local_md(target)
        if local is None:
            continue
        resolved = os.path.normpath(os.path.join(base, local))
        if not os.path.isfile(resolved):
            violations.append(f"{rel}  broken link -> {target}")
            continue
        if "#" not in target:
            continue
        anchor = target.split("#", 1)[1].lower()
        if not anchor:
            continue
        if resolved not in anchor_cache:
            anchor_cache[resolved] = heading_slugs(resolved)
        slugs = anchor_cache[resolved]
        if anchor in slugs:
            continue
        suffix = re.search(r"-(\d+)$", anchor)
        if suffix:
            stem = anchor[: suffix.start()]
            if slugs.get(stem, 0) > int(suffix.group(1)):
                continue
        violations.append(f"{rel}  broken anchor -> {target}")

# Index coverage: every docs/*.md must be mentioned by some other Markdown file.
docs_dir = os.path.join(repo, "docs")
contents = {p: read(p) for p in files}
for name in sorted(os.listdir(docs_dir)):
    if not name.endswith(".md") or name == "README.md":
        continue
    self_path = os.path.join(docs_dir, name)
    if not any(p != self_path and name in text for p, text in contents.items()):
        violations.append(f"docs/{name}  is referenced by no other Markdown file (orphaned)")

if violations:
    print("::error::Documentation makes claims that no longer hold:")
    for line in sorted(violations):
        print(f"  {line}")
    print("")
    print("Authoritative tripwire: Tests/ManifoldCoreTests/DocClaimsAuditTest.swift")
    sys.exit(1)

print(f"✓ {len(files)} Markdown files: links, anchors and index coverage all resolve.")
PYEOF
