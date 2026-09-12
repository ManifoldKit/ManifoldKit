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
# ── SCOPE: claim checks that a docs-only PR can break ───────────────────────
# Mirrored here (markdown-only, so a docs-only diff can break them):
#   1. relative `.md` links resolve on disk
#   2. `file.md#anchor` resolves to a real heading (GitHub slug rules)
#   3. DocC double-backtick symbols exist as source tokens
#   4. every top-level `docs/*.md` page is reachable by a navigable link from
#      a reader entrypoint (rather than merely mentioning its filename).
#
# A docs-only change *can* introduce a nonexistent ``Symbol`` claim.  This
# mirror intentionally uses the same modest promise as the Swift audit: token
# existence in Sources/, not public-API or declaration semantics.
#
# ── DRIFT GUARD ────────────────────────────────────────────────────────────
# Tests/ManifoldCoreTests/DocClaimsAuditTest.swift is AUTHORITATIVE for the
# RULES. Both run on a normal source PR, so a rule disagreement surfaces as one
# passing and the other failing rather than as silence. When you change a rule
# in the Swift audit, change it here in the same commit.
#
# One known CORPUS divergence where this script is deliberately STRICTER — if
# it fails and the Swift audit passes, check this before assuming the script is
# stale: a link target that is a *directory* named `foo.md`. Swift uses
#      `fileExists` (true for directories); python uses `os.path.isfile`.
# This is contrived, does not occur in the repo today, and stricter is the
# right direction — but "the Swift audit is right" would send you the wrong way.
#
# Exit codes: 0 clean; 1 violations found or corpus not located.
#
# Portability: bash 3.2 + python3 (ubuntu-latest and macOS both have both).

set -euo pipefail

REPO_ROOT="${MANIFOLD_DOC_CLAIMS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ ! -d "${REPO_ROOT}/docs" ]]; then
    echo "::error::docs/ not found at ${REPO_ROOT}/docs"
    exit 1
fi

echo "── doc-claims-lint: symbols, links, anchors, rooted reachability ────"

python3 - "$REPO_ROOT" <<'PYEOF'
import os, re, sys

repo = sys.argv[1]

EXCLUDED_PARTS = {".git", ".build", "DerivedData", "node_modules", "Fixtures", "fixture", "fixtures", "generated", "Generated", "runs", "dx-walkthrough"}

def corpus():
    """Maintained Markdown, excluding generated, fixture, and historical run trees."""
    files = []
    for name in sorted(os.listdir(repo)):
        if name.endswith(".md") and os.path.isfile(os.path.join(repo, name)):
            files.append(os.path.join(repo, name))
    for sub in ("docs", "Sources", "Tests", "scripts", "Example"):
        base = os.path.join(repo, sub)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            _dirnames[:] = [d for d in _dirnames if d not in EXCLUDED_PARTS and not d.startswith(".")]
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

def symbol_links(content):
    return re.findall(r"``([^`\n]+)``", content)

def identifiers(subject):
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*", subject.split("(", 1)[0])

def strip_comments_and_strings(source):
    """Conservative Swift scanner: no comment/string residue can vouch for a symbol."""
    out, i, n = [], 0, len(source)
    def blank(chunk):
        return ''.join('\n' if c == '\n' else ' ' for c in chunk)
    while i < n:
        if source.startswith('//', i):
            end = source.find('\n', i)
            end = n if end < 0 else end
            out.append(blank(source[i:end])); i = end; continue
        if source.startswith('/*', i):
            start, depth = i, 1; i += 2
            while i < n and depth:
                if source.startswith('/*', i): depth += 1; i += 2
                elif source.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            out.append(blank(source[start:i])); continue
        # Swift raw string: one or more # followed by quote.  The exact
        # closing delimiter is quote + the same number of # characters.
        hashes = 0
        while i + hashes < n and source[i + hashes] == '#': hashes += 1
        quote_at = i + hashes
        if hashes > 0 and quote_at < n and source[quote_at] == '"':
            triple = source.startswith('\"\"\"', quote_at)
            opener = 3 if triple else 1
            close = ('\"\"\"' if triple else '\"') + ('#' * hashes)
            start = i; i = quote_at + opener
            end = source.find(close, i)
            i = n if end < 0 else end + len(close)
            out.append(blank(source[start:i])); continue
        if source[i] == '"':
            triple = source.startswith('\"\"\"', i)
            start = i; i += 3 if triple else 1
            while i < n:
                if not triple and source[i] == '\\': i += 2; continue
                if triple and source.startswith('\"\"\"', i): i += 3; break
                if not triple and source[i] == '"': i += 1; break
                i += 1
            out.append(blank(source[start:i])); continue
        out.append(source[i]); i += 1
    return ''.join(out)

def source_tokens():
    tokens = set()
    source_root = os.path.join(repo, "Sources")
    if not os.path.isdir(source_root):
        raise RuntimeError("Sources/ not found; symbol check would be inert")
    for dirpath, dirnames, filenames in os.walk(source_root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_PARTS and not d.startswith(".")]
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            # Deliberately conservative stripping: comments/literals must not
            # vouch for a removed declaration, while this remains a token check.
            text = strip_comments_and_strings(read(os.path.join(dirpath, name)))
            tokens.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))
    for name in os.listdir(source_root):
        if os.path.isdir(os.path.join(source_root, name)):
            tokens.add(name)
    for dirpath, dirnames, filenames in os.walk(source_root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_PARTS and not d.startswith(".")]
        if ".docc" not in dirpath or ".docc/Extensions" in dirpath:
            continue
        for name in filenames:
            if name.endswith(".md"):
                tokens.add(os.path.splitext(name)[0])
    if not tokens:
        raise RuntimeError("Sources/ yielded zero Swift tokens; symbol check would be inert")
    return tokens

files = corpus()
if os.environ.get("MANIFOLD_DOC_CLAIMS_SKIP_FLOORS") != "1" and len(files) < 90:
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
if os.environ.get("MANIFOLD_DOC_CLAIMS_SKIP_FLOORS") != "1" and len(docs_top) < 40:
    print(f"::error::Only {len(docs_top)} docs/*.md found — the link, anchor and orphan checks would vacuously pass")
    sys.exit(1)

violations = []
anchor_cache = {}
try:
    tokens = source_tokens()
except RuntimeError as error:
    print(f"::error::{error}")
    sys.exit(1)

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

    for link in symbol_links(read(path)):
        for identifier in identifiers(link):
            # This matches the Swift audit's one external companion exception.
            if identifier not in tokens and identifier != "LlamaBackend":
                violations.append(f"{rel}  symbol ``{link}`` -> `{identifier}` not found in Sources/")

# Rooted reachability.  A and B linking only to one another are still orphaned:
# discovery begins at reader entrypoints, and only navigable local .md links
# advance the graph.  Filename mentions intentionally do not count.
docs_dir = os.path.join(repo, "docs")
managed = set(files)
entrypoints = [os.path.join(repo, p) for p in ("README.md", "AGENTS.md", "CONTRIBUTING.md", "docs/README.md")]
queue = [p for p in entrypoints if p in managed]
queue += [p for p in managed if os.path.basename(os.path.dirname(p)).endswith(".docc")]
reachable = set(queue)
while queue:
    path = queue.pop(0)
    for target in re.findall(r"\]\(([^)\s]+)\)", read(path)):
        local = local_md(target)
        if local is None:
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), local))
        if resolved in managed and resolved not in reachable:
            reachable.add(resolved)
            queue.append(resolved)
for path in sorted(os.path.join(docs_dir, name) for name in os.listdir(docs_dir)
                   if name.endswith(".md") and name != "README.md" and os.path.isfile(os.path.join(docs_dir, name))
                   if os.path.join(docs_dir, name) not in reachable):
    violations.append(f"{os.path.relpath(path, repo)}  is not reachable by a navigable Markdown link from README/docs README/contributor entrypoints")

if violations:
    print("::error::Documentation makes claims that no longer hold:")
    for line in sorted(violations):
        print(f"  {line}")
    print("")
    print("Authoritative tripwire: Tests/ManifoldCoreTests/DocClaimsAuditTest.swift")
    sys.exit(1)

print(f"✓ {len(files)} maintained Markdown files: symbols, links, anchors and rooted reachability resolve.")
PYEOF
