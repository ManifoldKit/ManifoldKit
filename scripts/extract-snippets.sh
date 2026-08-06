#!/usr/bin/env bash
# extract-snippets.sh — Extract fenced Swift code blocks from the documentation
# corpus into standalone .swift files for downstream compilation.
#
# Wave D-C1 of the DX overhaul: the README's Hello World snippet is the
# single most important piece of copy-paste correctness in the repo. This
# script (plus its companion compile gate) makes "a future PR silently
# breaks the snippet" a CI failure rather than a Slack apology.
#
# Coverage (see SNIPPET_GATE_OPT_OUT below for the full rationale):
#   - every root-level *.md and every docs/*.md, minus a reasoned opt-out list
#   - every Markdown file inside a `.docc/` directory under Sources/
# Coverage is DERIVED from the filesystem, not enumerated: a new doc is gated
# on creation, and excluding one is a reviewable diff line with a reason.
#
# What it does:
#   - Pulls out every fenced block tagged ```swift (case-insensitive).
#   - Numbers them per-file with a %03d index (readme-001.swift,
#     docc-manifoldui-buildingachatui-001.swift, ...). The slug is the
#     lowercased basename; the 3-digit suffix is what makes a per-doc glob
#     exact, since one slug can prefix another (quickstart / quickstart-cli).
#   - Writes each to --out <dir> (default a fresh, process-unique dir under
#     $TMPDIR/manifoldkit-snippets-<pid>; pass --out explicitly for a stable
#     path) with a `// Source: <relative-path>:<line>` header so failures
#     point back to docs.
#
# Skip / include policy:
#   - ```swift,no-build:<reason> records a `.skip` marker instead of a
#     `.swift` file. The reason is MANDATORY — a bare `no-build` is rejected
#     mirroring ScriptFailOpenAuditTest's `# fail-open-ok: <reason>` rule. Use
#     it for genuinely partial snippets; the Hello World MUST never carry it.
#     Legacy bare tags are budgeted per-doc by scripts/snippet-skip-baseline.tsv
#     (a ratchet: a doc may keep what it had, never gain one).
#   - A doc that has been triaged (not grandfathered) must compile at least
#     one block. A doc where everything is skipped costs a full macOS run per
#     edit and verifies nothing.
#   - Snippets whose first non-comment line starts with `.package(` or
#     `.target(` (or that lead with `import PackageDescription`) are
#     heuristically classified as Package.swift fragments and written to
#     `.skip` files. These cannot be compiled standalone, but they are NOT
#     trusted blindly: scripts/extract-snippets-test.sh validates every such
#     fragment against Package.swift (referenced products must exist; a
#     `.v26` platform requires swift-tools-version >= 6.2). Version-pin
#     freshness lint additionally lives in scripts/check-readme.sh.
#
# Exit codes:
#   0 — extracted at least one Swift block across all inputs.
#   1 — usage error or I/O failure.
#   2 — a policy failure, one of:
#         * zero Swift blocks found anywhere (defensive)
#         * a `no-build:` tag whose reason is missing or too short
#         * a triaged doc with no compiling block at all
#         * a per-doc skip count that ROSE above its recorded budget
#         * a per-doc skip count that FELL without the budget being lowered
#         * a non-numeric count in the baseline (would disable the ratchet)
#         * the baseline not matching the tree (stale or malformed rows)
#       Regenerate the budget with --update-baseline.
#
# Portability: BSD awk/sed/grep only (macOS default toolchain). No grep -P.
# Also runs on GNU userland: `snippet-policy-lint` (.github/workflows/lint.yml)
# executes this script on ubuntu-latest, so keep every external invocation to
# the intersection of BSD and GNU behaviour. Requires no Swift toolchain — that
# is what allows the policy checks to live in the required `lint` job at all.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Process-unique default so two concurrent manual runs don't clobber each
# other's output (they used to share a fixed /tmp/manifoldkit-snippets path,
# and the cleanup rm at the top of extraction would glob-delete the other
# run's files out from under it). CI always passes --out explicitly
# (extract-snippets-test.sh), so this default only affects manual runs.
OUT_DIR="${TMPDIR:-/tmp}/manifoldkit-snippets-$$"
VERBOSE=0
UPDATE_BASELINE=0

usage() {
    cat <<EOF
Usage: $0 [--out <dir>] [--verbose] [--update-baseline]

Options:
  --out <dir>          Output directory (default: a fresh, process-unique dir
                        under \$TMPDIR/manifoldkit-snippets-<pid>).
  --verbose            Log each extracted block to stderr.
  --update-baseline    Rewrite scripts/snippet-skip-baseline.tsv from the
                        current tree instead of enforcing against it. Use after
                        legitimately adding or removing a skipped block, and say
                        in the PR why a count moved.
  -h, --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Coverage is DERIVED, not enumerated ──────────────────────────────────
#
# Every `README.md`, `AGENTS.md`, and `docs/*.md` is swept unless it appears in
# SNIPPET_GATE_OPT_OUT below. That default is the whole point: this list used to
# be an enumeration of filenames, and an enumeration is always one incident
# behind. It grew reactively eight times (#1397 added CLI the day the CLI doc
# landed, #1417 added DocC after BuildingAChatUI.md broke, #1680 after BYO
# drift, #2331 added SWIFTUI-MULTI-SESSION + RECIPES), and #2331 — titled "fix
# accuracy drift in AGENTS, recipes, …" — still did not add AGENTS.md, the file
# named first in its own title. A new doc is now covered on creation; excluding
# one is a reviewable diff line with a reason attached.
#
# For the same reason there is no second copy of this list: the `INPUTS=(…)`
# array that used to live here was dead code, never referenced by anything,
# while the real list was a column of hardcoded `extract_one` calls further
# down. Two lists, one inert — so updating the obvious one changed nothing.
#
# Format: "<repo-relative path>:<reason>". A bare path with no reason is
# rejected, mirroring ScriptFailOpenAuditTest's `# fail-open-ok: <reason>` rule.
SNIPPET_GATE_OPT_OUT=(
    # Prose/reference docs with no consumer-pasteable Swift. Cheap to gate, but
    # nothing to gain — no fenced Swift at all, or only shell/JSON.
    # Root-level docs. Swept by the glob above, so each needs a line here or
    # it is gated — that is the point of the inversion.
    "CHANGELOG.md:release history; 159 fences are historical release-note excerpts, not consumer recipes"
    "CLAUDE.md:stub importing AGENTS.md; no Swift"
    "CODE_OF_CONDUCT.md:policy text; no Swift"
    "CONTRIBUTING.md:contributor prose; no Swift"
    "RELEASE.md:release runbook; no Swift"
    "TESTING.md:untriaged — 12 fences, contributor test recipes"
    "SECURITY.md:untriaged — 4 fences"
    "FUZZING.md:untriaged — 2 fences"

    "docs/README.md:index page; no Swift"
    "docs/FIPS.md:regulatory prose; no Swift"
    "docs/THREAT_MODEL.md:threat-model prose; Swift appears only as attack illustrations"
    "docs/RELIABILITY.md:reliability contract prose; no consumer Swift"
    "docs/POSITIONING.md:category argument; no consumer Swift"
    "docs/SCOPE_DECISION.md:scope rationale; no consumer Swift"
    "docs/PRODUCTION-READINESS.md:maturity matrix; no consumer Swift"
    "docs/API-DESIGN.md:policy doc; illustrative signatures only"
    "docs/RELEASE-1.0.md:release policy; no consumer Swift"
    "docs/QA-PRACTICES.md:contributor QA prose; no consumer Swift"
    "docs/QA-EVALUATION-PROCESS.md:contributor QA prose; no consumer Swift"
    "docs/TESTING-CI-PRINCIPLES.md:contributor CI prose; no consumer Swift"
    "docs/HARDWARE-TOOLCHAIN.md:hardware/toolchain notes; shell not Swift"
    "docs/TRAIT-COSTS.md:measurement tables; no consumer Swift"
    "docs/FeatureMatrix.md:trait table; no Swift"
    "docs/SOURCEKIT_DIAGNOSTICS.md:diagnostic runbook; shell not Swift"
    "docs/LLAMA_CONTRACT.md:tombstone pointing at manifold-llama"
    "docs/LOCAL-GGUF.md:storage-contract prose; no consumer Swift"
    "docs/ANATOMY-OF-ONE-TURN.md:internal turn walkthrough; no fenced Swift"
    "docs/MIGRATION-INDEX.md:index page; no Swift"
    "docs/AppStoreSubmission.md:submission checklist; single plist-shaped fence"
    "docs/UI-REFRESH-2026.md:design rationale; no consumer Swift"
    "docs/UI-REFRESH-2026-PLAN.md:internal delivery plan; no consumer Swift"
    "docs/wwdc-2026-trait-stubs.md:stubs for unshipped Apple API — cannot compile by construction"
    "docs/COMPANION-BACKENDS.md:companion-authoring guide; snippets target another package's module"
    "docs/APP-EVAL.md:ManifoldAppEval is not linked by the gate's test target"
    "docs/QUICKSTART-SERVER.md:server binary usage; shell not Swift"
    "docs/CLOUD-OAUTH.md:host-side OAuth patterns; snippets reference host-defined types"
    # Previously omitted by accident: the workflow `paths:` filter globbed
    # docs/QUICKSTART*.md while the extractor used an explicit list this file
    # was missing from, so editing it triggered a ~14-min run that compiled
    # nothing from it. Now an explicit, reasoned decision — its five fences all
    # construct MLXDiffusionBackend, which lives in the manifold-mlx companion
    # package and cannot be linked from core.
    "docs/QUICKSTART-IMAGE-GEN.md:snippets construct MLXDiffusionBackend — manifold-mlx type, not linkable from core"

    # ── Untriaged backlog ────────────────────────────────────────────────
    # These DO carry consumer-pasteable Swift and SHOULD be gated. They are
    # opted out only because nobody has verified their snippets compile yet —
    # exactly the debt this inversion is meant to surface rather than hide.
    # Removing an entry here is the unit of progress; do not add one.
    "docs/MIGRATION-0.48.md:untriaged — 8 fences, historical migration snippets"
    "docs/MIGRATION-shims-retired.md:untriaged — 5 fences"
    "docs/MIGRATION-ui-refresh.md:untriaged — 4 fences"
    "docs/MIGRATION-history-through-hints.md:untriaged — 2 fences"
    "docs/MIGRATION-compression-policy-system-prompt.md:untriaged — 2 fences"
    "docs/MIGRATION-enum-growth-sweep-2208.md:untriaged — 1 fence"
    "docs/MIGRATION-cost-estimation-removed.md:untriaged — 1 fence"
    "docs/MIGRATION-wake-word-removed.md:untriaged — host-side replacement recipe"
    "docs/MIGRATING-FROM-FOUNDATION-MODELS.md:untriaged — 5 fences"
    "docs/MODEL-MANAGEMENT.md:untriaged — 4 fences"
    "docs/LOCAL-TOOL-CALLING.md:untriaged — 4 fences, prompt-envelope illustrations"
    "docs/RAG-TUNING.md:untriaged — 3 fences"
    "docs/share-action-extension-recipe.md:untriaged — 3 fences, app-extension host code"
)

# is_opted_out <repo-relative-path> — true when the doc is on the opt-out list.
# A bare entry with no `:<reason>` is a hard error: an unexplained exclusion is
# how coverage quietly rots.
is_opted_out() {
    local needle="$1" entry path reason
    for entry in "${SNIPPET_GATE_OPT_OUT[@]}"; do
        path="${entry%%:*}"
        reason="${entry#*:}"
        if [[ "$path" == "$needle" ]]; then
            if [[ -z "$reason" || "$reason" == "$entry" ]]; then
                echo "::error::SNIPPET_GATE_OPT_OUT entry '$entry' has no reason. Add ':<why>'." >&2
                exit 2
            fi
            return 0
        fi
    done
    return 1
}

# ── Bare-`no-build` ratchet ───────────────────────────────────────────────
#
# A bare ```swift,no-build (no reason) is legacy debt. Rather than a register of
# FILES that may contain them — which grants the file, not the blocks, so a
# listed doc could accrue unlimited new bare tags, and which exempted every DocC
# article wholesale — the budget is a committed per-doc COUNT. A doc may keep the
# bare tags it had; it may not gain one. Removing them is the unit of progress.
#
# Both adversarial reviews of #2385 called this strictly better than the
# register: it closes the two holes the register left (new DocC articles, new
# blocks in listed files) without needing anyone to triage first. It was declined
# there for diff size, with the decline recorded in-tree; this is that follow-up.
#
# The baseline lives in scripts/snippet-skip-baseline.tsv, one row per doc:
#   <repo-relative path>\t<bare no-build count>\t<total skipped count>
#
# A legitimate new fragment DOES require bumping a count — that is the design.
# The bump is a reviewable line in the diff, which is exactly the visibility the
# invisible bare tag never had. Regenerate with:
#   scripts/extract-snippets.sh --update-baseline
BASELINE_FILE="$REPO_ROOT/scripts/snippet-skip-baseline.tsv"

# baseline_field <path> <column 2|3> — the recorded count, or 0 if unlisted.
baseline_field() {
    local needle="$1" col="$2" value
    [[ -f "$BASELINE_FILE" ]] || { printf '0'; return; }
    value=$(awk -F'\t' -v n="$needle" -v c="$col" '$1 == n { print $c; found=1 } END { if (!found) print 0 }' \
        "$BASELINE_FILE" | head -1)
    # Reject anything non-numeric LOUDLY. `[[ x -gt y ]]` on a junk operand
    # raises an arithmetic error, `[[ ]]` then returns 1 (false), and `set -e`
    # does not fire because the comparison sits in an `if` condition — so a
    # single stray CR (a TSV saved with CRLF endings) silently disables the
    # entire ratchet while the script exits 0 and prints no annotation. That is
    # the worst possible failure: an inert guard that looks green.
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "::error file=scripts/snippet-skip-baseline.tsv::column ${col} for '${needle}' is not a number (got '${value}'). Check for CRLF line endings, a missing column, or spaces instead of tabs — a non-numeric value would silently disable the ratchet." >&2
        exit 2
    fi
    printf '%s' "$value"
}

# docc_slug_for <Sources/<Module>/<Module>.docc/...> — `docc-<module>-<file>`,
# both lowercased. Shared by extraction and the ratchet so the two cannot
# disagree about which output files belong to which article.
docc_slug_for() {
    local docc_rel="$1" module_path module_name file_base
    module_path="${docc_rel%%.docc/*}"
    module_name="${module_path##*/}"
    file_base="$(basename "$docc_rel" .md)"
    printf 'docc-%s-%s' \
        "$(printf '%s' "$module_name" | tr '[:upper:]' '[:lower:]')" \
        "$(printf '%s' "$file_base" | tr '[:upper:]' '[:lower:]')"
}

# slug_for <repo-relative-path> — lowercased basename without the extension.
# Derived, so a new doc needs no slug registration.
slug_for() {
    local base
    base="$(basename "$1" .md)"
    printf '%s' "$base" | tr '[:upper:]' '[:lower:]'
}

mkdir -p "$OUT_DIR"
# Clean any prior run so a deleted snippet doesn't linger as a stale file.
# This used to be a hand-maintained column of per-slug prefix globs
# (readme-*, quickstart-rag-*, why-*, …) — a third filename list to keep in
# sync, and one that would silently leak stale files the moment a doc gained a
# slug nobody added a glob for. Slugs are derived now, so match on extension:
# OUT_DIR is a dedicated snippets directory, so nothing else lives here.
rm -f "$OUT_DIR"/*.swift "$OUT_DIR"/*.skip 2>/dev/null || true  # fail-open-ok: best-effort cleanup of prior outputs — globs may match nothing

total=0
total_skipped=0

# extract_one <path> <slug>
#
# Reads $path and emits one file per fenced ```swift block into $OUT_DIR.
# Uses awk because Markdown fence parsing is line-oriented and benefits
# from a single pass with state. BSD awk is the floor.
extract_one() {
    local rel_path="$1"
    local slug="$2"
    local abs_path="$REPO_ROOT/$rel_path"

    if [[ ! -f "$abs_path" ]]; then
        echo "::error::Input file not found: $abs_path" >&2
        return 1
    fi

    # awk emits per-block markers prefixed with $$$BLOCK$$$ so this shell can
    # iterate them. We avoid temp files inside awk to keep the script
    # self-contained.
    local awk_out
    awk_out=$(awk '
        BEGIN { in_block = 0; block_num = 0; start_line = 0; tag = ""; }
        # Detect opening fence. Case-insensitive match on "swift" after ```.
        # Tolerates ```swift, ```swift,no-build, ```Swift, ```swift foo, etc.
        /^```/ {
            if (in_block == 0) {
                # Lowercase the line for tag matching without disturbing the
                # captured fence tag itself.
                lower = tolower($0)
                # Strip the leading ``` then check the language token.
                rest = substr(lower, 4)
                # Match "swift" at the start, optionally followed by ,/space/EOL.
                if (rest ~ /^swift([,[:space:]]|$)/) {
                    in_block = 1
                    block_num += 1
                    start_line = NR + 1
                    tag = rest
                    print "$$$START$$$" block_num "|" start_line "|" tag
                    next
                }
            } else {
                # Closing fence.
                in_block = 0
                print "$$$END$$$" block_num
                tag = ""
                next
            }
        }
        in_block == 1 { print "$$$BODY$$$" block_num "|" $0 }
    ' "$abs_path")

    # Reconstruct blocks in shell. We iterate the awk output, buffering
    # body lines until we hit the END marker.
    local cur_num=""
    local cur_start=""
    local cur_tag=""
    local cur_body=""
    local first_body_line=1

    while IFS= read -r line; do
        case "$line" in
            '$$$START$$$'*)
                payload="${line#'$$$START$$$'}"
                cur_num="${payload%%|*}"
                rest="${payload#*|}"
                cur_start="${rest%%|*}"
                cur_tag="${rest#*|}"
                cur_body=""
                first_body_line=1
                ;;
            '$$$BODY$$$'*)
                payload="${line#'$$$BODY$$$'}"
                body_line="${payload#*|}"
                if [[ $first_body_line -eq 1 ]]; then
                    cur_body="$body_line"
                    first_body_line=0
                else
                    cur_body="$cur_body"$'\n'"$body_line"
                fi
                ;;
            '$$$END$$$'*)
                # Format index as 3-digit zero-padded.
                idx=$(printf "%03d" "$cur_num")
                out_base="$OUT_DIR/${slug}-${idx}"

                # Decide skip / keep.
                local skip_reason=""
                # Explicit no-build tag.
                # `no-build` must carry a reason: ```swift,no-build:<why>.
                #
                # A bare tag costs nothing to write and hides everything behind
                # it — which is how 176 of 207 blocks (85%) ended up skipped,
                # and how docs/QUICKSTART-VOICE.md advertised a subsystem
                # deleted five weeks earlier. Requiring a reason puts the
                # justification in the diff where a reviewer sees it, exactly
                # as ScriptFailOpenAuditTest requires `# fail-open-ok: <reason>`
                # for a `|| true`. Same hazard, same remedy.
                case "$cur_tag" in
                    *no-build:*)
                        no_build_reason="${cur_tag#*no-build:}"
                        # Trim a trailing fence-tag remnant and whitespace.
                        no_build_reason="$(printf '%s' "$no_build_reason" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
                        if [[ ${#no_build_reason} -lt 12 ]]; then
                            echo "::error file=${rel_path},line=$((cur_start - 1))::\`no-build\` reason is missing or too short (\"${no_build_reason}\"). Write why this block cannot compile, e.g. \`\`\`swift,no-build:fragment; builds on identifiers defined in earlier blocks" >&2
                            exit 2
                        fi
                        skip_reason="no-build: ${no_build_reason}"
                        ;;
                    *no-build*)
                        # Counted, not rejected here: the per-doc ratchet below
                        # decides, so legacy debt survives while a NEW bare tag
                        # in any doc — including a brand-new DocC article — fails.
                        skip_reason="explicit-no-build-tag (bare; counted against the ratchet)"
                        ;;
                esac

                # Heuristic: Package.swift fragment.
                if [[ -z "$skip_reason" ]]; then
                    # First non-blank, non-comment line.
                    first_meaningful=$(printf '%s\n' "$cur_body" \
                        | sed -E '/^[[:space:]]*$/d; /^[[:space:]]*\/\//d' \
                        | head -n 1)
                    case "$first_meaningful" in
                        .package\(* | .target\(* )
                            skip_reason="package-manifest-fragment"
                            ;;
                        "import PackageDescription"* )
                            # Full Package.swift snippet — recognisable by the
                            # leading PackageDescription import. These cannot
                            # compile as executable target sources; treat them
                            # the same as the smaller .package(...) fragments.
                            skip_reason="package-manifest-fragment"
                            ;;
                    esac
                fi

                if [[ -n "$skip_reason" ]]; then
                    {
                        printf '# Source: %s:%s\n' "$rel_path" "$cur_start"
                        printf '# Skip reason: %s\n' "$skip_reason"
                        printf '# Fence tag: %s\n' "$cur_tag"
                        printf -- '---\n'
                        printf '%s\n' "$cur_body"
                    } > "${out_base}.skip"
                    total_skipped=$((total_skipped + 1))
                    if [[ $VERBOSE -eq 1 ]]; then
                        echo "skip  ${out_base}.skip  (${skip_reason})  ${rel_path}:${cur_start}" >&2
                    fi
                else
                    {
                        printf '// Source: %s:%s\n' "$rel_path" "$cur_start"
                        printf '%s\n' "$cur_body"
                    } > "${out_base}.swift"
                    total=$((total + 1))
                    if [[ $VERBOSE -eq 1 ]]; then
                        echo "keep  ${out_base}.swift  ${rel_path}:${cur_start}" >&2
                    fi
                fi

                cur_num=""
                cur_start=""
                cur_tag=""
                cur_body=""
                ;;
        esac
    done <<<"$awk_out"
}

# Every root-level *.md and every docs/*.md, minus the reasoned opt-outs above.
#
# Root files are swept by glob rather than named: listing "README.md" and
# "AGENTS.md" explicitly left TESTING.md (12 fences), SECURITY.md (4) and
# FUZZING.md (2) ungated with no opt-out line — silently uncovered, which is
# the exact property this rewrite exists to remove.
#
# `docs/` is maxdepth 1 on purpose: its subdirectories (plans/, design/,
# images/) are internal working material, not published guides. The workflow
# `paths:` filter is scoped to match, so no doc can trigger the gate without
# being swept by it.
#
# No `2>/dev/null` on the find: a masked producer here would yield an empty
# sweep and a green run off the remaining inputs — the zero-match-parse shape
# this PR is otherwise arguing against.
# Each sweep is captured by ASSIGNMENT, then iterated, rather than read from a
# `< <(…)` process substitution. A process-substitution producer's exit status is
# unobservable — not by `set -e`, not by `pipefail` — so a `find` that failed
# partway (permission or IO error after emitting some paths) would silently
# narrow what this gate checks and the run would still exit 0. The comment below
# used to anticipate only the stderr-masking half of that; no amount of unmasked
# stderr makes an ignored status visible. In assignment position a failing
# producer kills the script.
gated_docs=()
root_md_sweep="$(cd "$REPO_ROOT" && find . -maxdepth 1 -type f -name '*.md' | sed 's|^\./||' | LC_ALL=C sort)"
while IFS= read -r doc_rel; do
    [[ -n "$doc_rel" ]] && gated_docs+=("$doc_rel")
done <<<"$root_md_sweep"
docs_md_sweep="$(cd "$REPO_ROOT" && find docs -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)"
while IFS= read -r doc_rel; do
    [[ -n "$doc_rel" ]] && gated_docs+=("$doc_rel")
done <<<"$docs_md_sweep"

for doc_rel in ${gated_docs[@]+"${gated_docs[@]}"}; do
    is_opted_out "$doc_rel" && continue
    extract_one "$doc_rel" "$(slug_for "$doc_rel")"
done

# DocC catalogs. Walk every Markdown file inside any Sources/*/Documentation.docc/
# directory (including nested Articles/, Extensions/, etc.). Slug pattern is
# `docc-<module>-<filename>` (both lowercased) so test output stays greppable
# per-article. `find` is used for portability — BSD find on macOS supports
# `-path` with shell globbing.
docc_files=()
# Assignment, not a process substitution — see the note above. The `2>/dev/null`
# that used to be here is gone too: this sweep feeds 57 of the 74 baseline rows,
# and it was the one site where the error was masked AND the status unobservable,
# i.e. both halves of the shape this file argues against.
docc_sweep="$(cd "$REPO_ROOT" && find Sources -type f -name '*.md' -path '*/*.docc/*' | LC_ALL=C sort)"
while IFS= read -r path; do
    [[ -n "$path" ]] && docc_files+=("$path")
done <<<"$docc_sweep"

for docc_rel in ${docc_files[@]+"${docc_files[@]}"}; do
    # Derive module name from the .docc directory: Sources/<Module>/<Module>.docc/...
    # Take everything up to ".docc" then strip the last path component to get the
    # module name. Example:
    #   Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md
    #     module = ManifoldUI, file = BuildingAChatUI
    extract_one "$docc_rel" "$(docc_slug_for "$docc_rel")"
done

echo "Extracted ${total} Swift snippet(s) and skipped ${total_skipped} fragment(s) into ${OUT_DIR}"

# ── Per-doc coverage: a triaged doc must compile at least one block ───────
#
# The pre-existing guard was global — "did extraction write zero .swift files
# across ALL inputs" — so a doc contributing nothing but .skip files passed
# silently as long as some other doc compiled something. Four docs
# (QUICKSTART-TOOLS, -MODEL-SELECTION, -VOICE, RECIPES) sat at 100% skipped
# while still triggering a ~14-minute macOS run on every edit: full latency
# cost, zero signal.
#
# Scope matches the debt register: a doc that has been triaged (not
# grandfathered) must earn real coverage. Grandfathered docs and DocC articles
# are exempt until their own triage pass — 28 DocC articles are currently at
# zero, which is the next tranche of this work, not a reason to weaken the rule
# where it already holds.
coverage_failures=0
for doc_rel in ${gated_docs[@]+"${gated_docs[@]}"}; do
    is_opted_out "$doc_rel" && continue
    # Exempt docs that still carry legacy bare tags — they are untriaged by
    # definition. Data-driven now, rather than a second hand-kept list: as the
    # ratchet drains a doc's bare count to 0, this assertion starts applying to
    # it automatically.
    # Hoisted to an assignment, NOT inlined in the `[[ ]]` below. baseline_field
    # exits 2 on a non-numeric count, and that exit only propagates through an
    # assignment (`set -e` fires on a failed command substitution). Inside a
    # `[[ ]]` test the failure is swallowed and the branch is taken anyway — so
    # the inline form left this call site fail-open on exactly the junk value the
    # validation was added to catch, while the ratchet's own call sites were
    # protected. Verified both shapes directly under /bin/bash.
    doc_baseline_bare=$(baseline_field "$doc_rel" 2)
    [[ "$doc_baseline_bare" != "0" ]] && continue
    doc_slug="$(slug_for "$doc_rel")"
    # `find`, not `ls`: a no-match glob makes `ls` exit non-zero, and under
    # `set -euo pipefail` that aborts the script before this check can report —
    # the assertion would be structurally incapable of firing. `find` exits 0
    # on no matches.
    #
    # The `-[0-9][0-9][0-9]` suffix is load-bearing, NOT decoration: block
    # indices are written with `printf "%03d"`, and a bare `${doc_slug}-*`
    # glob also matches every sibling whose slug shares this prefix —
    # `quickstart-*` matches all 18 of quickstart-cli/-rag/-tools/-voice's
    # files while only 4 are its own. With the loose glob this assertion was
    # vacuous for exactly the doc most likely to be triaged next.
    compiled_count=$(find "$OUT_DIR" -maxdepth 1 -name "${doc_slug}-[0-9][0-9][0-9].swift" | wc -l | tr -d ' ')
    skipped_count=$(find "$OUT_DIR" -maxdepth 1 -name "${doc_slug}-[0-9][0-9][0-9].skip" | wc -l | tr -d ' ')
    if [[ "$compiled_count" -eq 0 && "$skipped_count" -gt 0 ]]; then
        echo "::error file=${doc_rel}::every Swift block in this doc is skipped, so the snippet gate runs on it and verifies nothing. Make at least one block compile, or move the doc to SNIPPET_GATE_OPT_OUT with a reason." >&2
        coverage_failures=$((coverage_failures + 1))
    fi
done
# --update-baseline records current state; enforcing against a baseline that does
# not exist yet is the chicken-and-egg that made the first run unable to bootstrap
# (with no baseline every doc reads as fully triaged, so the coverage assertion
# fired before the file could be written).
if [[ $coverage_failures -gt 0 && $UPDATE_BASELINE -eq 0 ]]; then
    exit 2
fi

# ── Ratchet: per-doc skip counts may fall, never rise ─────────────────────
#
# Counts are derived from the emitted .skip files rather than threaded through
# the extraction loop: each one records its own `# Skip reason:` line, so the
# output is the single source of truth and cannot drift from what was written.
ratchet_rows=""
ratchet_failures=0
for doc_rel in ${gated_docs[@]+"${gated_docs[@]}"} ${docc_files[@]+"${docc_files[@]}"}; do
    is_opted_out "$doc_rel" && continue
    doc_slug="$(slug_for "$doc_rel")"
    case "$doc_rel" in
        Sources/*) doc_slug="$(docc_slug_for "$doc_rel")" ;;
    esac

    total_skips=$(find "$OUT_DIR" -maxdepth 1 -name "${doc_slug}-[0-9][0-9][0-9].skip" | wc -l | tr -d ' ')
    # `while read`, not `for … in $(find …)`: the unquoted command substitution
    # word-splits, so an OUT_DIR containing a space made this count 0 bare tags
    # and the bare arm degraded to "found nothing" instead of erroring. CI's
    # OUT_DIR has no spaces, so that was latent — but a detection path that
    # silently reads zero is exactly what this whole gate exists to prevent.
    # Assignment, not a process substitution. This site was only *accidentally*
    # safe: the identical `find` runs in an assignment two lines up, so under
    # `pipefail` a failing find already killed the script before reaching here —
    # protection that existed purely as an artifact of statement order, and that
    # swapping those two lines would have silently removed, re-opening the
    # read-zero fail-open fixed above by a different route.
    bare_skips=0
    bare_skip_files="$(find "$OUT_DIR" -maxdepth 1 -name "${doc_slug}-[0-9][0-9][0-9].skip")"
    while IFS= read -r skip_file; do
        [[ -n "$skip_file" ]] || continue
        if grep -q '^# Skip reason: explicit-no-build-tag (bare' "$skip_file"; then
            bare_skips=$((bare_skips + 1))
        fi
    done <<<"$bare_skip_files"

    ratchet_rows="${ratchet_rows}${doc_rel}	${bare_skips}	${total_skips}
"

    baseline_bare=$(baseline_field "$doc_rel" 2)
    baseline_total=$(baseline_field "$doc_rel" 3)
    # Three INDEPENDENT checks, not an if/elif chain. Chained, with the low arm
    # first, a fall in one column suppressed a rise in the other — so triaging one
    # bare tag away while adding two new fragments printed only "counts FELL" and
    # never the rise annotation, and the remedy it offered (--update-baseline)
    # recorded the rise. The low arm laundered exactly what the high arms exist to
    # catch. Each arm now reports its own column and nothing masks anything.
    #
    # The low arm is what makes this a ratchet rather than a high-water mark:
    # without it, draining a doc's skips leaves permanent invisible headroom a
    # later PR can spend silently. It also self-guards the counter — a change that
    # breaks counting reads 0 everywhere and goes instantly red here.
    if [[ "$bare_skips" -lt "$baseline_bare" ]]; then
        echo "::error file=${doc_rel}::bare no-build count FELL ${baseline_bare} → ${bare_skips} — good, but the budget must come down with it or it becomes headroom a later PR can spend silently. Run: scripts/extract-snippets.sh --update-baseline (if that itself fails on a malformed baseline, delete the file and regenerate)." >&2
        ratchet_failures=$((ratchet_failures + 1))
    fi
    if [[ "$total_skips" -lt "$baseline_total" ]]; then
        echo "::error file=${doc_rel}::total skipped count FELL ${baseline_total} → ${total_skips} — lower the budget with it: scripts/extract-snippets.sh --update-baseline. Note that dropping a doc's bare count to 0 also switches on the \">=1 compiled block\" assertion for it, so it may then require a compiling block or an opt-out." >&2
        ratchet_failures=$((ratchet_failures + 1))
    fi
    if [[ "$bare_skips" -gt "$baseline_bare" ]]; then
        echo "::error file=${doc_rel}::bare \`swift,no-build\` count rose ${baseline_bare} → ${bare_skips}. A bare tag has no reason attached, so nothing records why the block cannot compile. Add \`no-build:<why>\`, or make the block compile. (If this is genuinely new legacy debt, bump the count in scripts/snippet-skip-baseline.tsv and say why in the PR.)" >&2
        ratchet_failures=$((ratchet_failures + 1))
    fi
    if [[ "$total_skips" -gt "$baseline_total" ]]; then
        echo "::error file=${doc_rel}::skipped-block count rose ${baseline_total} → ${total_skips}. Prefer making the new block compile; if it genuinely cannot, bump the count in scripts/snippet-skip-baseline.tsv so the increase is visible in review." >&2
        ratchet_failures=$((ratchet_failures + 1))
    fi
done

# ── Backstop: the baseline must equal the tree, exactly ───────────────────
#
# The per-doc arms above only consult rows a *currently gated doc* looks up, so
# they are blind to rows for docs that no longer exist: delete or newly opt out a
# doc and its row is never validated again. That is not merely untidy — recreate
# `docs/FOO.md` later and its stale `3 3` row silently grants three bare tags
# with no TSV diff and no annotation, which is the hole the low arm was added to
# close. This whole-file comparison closes it, catches formatting junk in rows
# nothing looks up, and makes the per-doc arms impossible to regress past.
if [[ $UPDATE_BASELINE -eq 0 && -f "$BASELINE_FILE" ]]; then
    expected_rows="$(printf '%s' "$ratchet_rows" | LC_ALL=C sort)"
    actual_rows="$(grep -v '^[[:space:]]*#' "$BASELINE_FILE" | grep -v '^[[:space:]]*$' | LC_ALL=C sort || true)"  # fail-open-ok: grep exits 1 on an all-comment baseline, which the comparison below then reports as a mismatch
    if [[ "$expected_rows" != "$actual_rows" ]]; then
        echo "::error file=scripts/snippet-skip-baseline.tsv::baseline does not match the tree. Rows exist for docs that are gone or newly opted out, or a row is malformed. Run: scripts/extract-snippets.sh --update-baseline" >&2
        printf '%s\n' "--- recorded but not produced by this run:" >&2
        comm -13 <(printf '%s\n' "$expected_rows") <(printf '%s\n' "$actual_rows") >&2 || true  # fail-open-ok: diagnostic only; the mismatch above already failed the gate
        printf '%s\n' "--- produced but not recorded:" >&2
        comm -23 <(printf '%s\n' "$expected_rows") <(printf '%s\n' "$actual_rows") >&2 || true  # fail-open-ok: diagnostic only; the mismatch above already failed the gate
        ratchet_failures=$((ratchet_failures + 1))
    fi
fi

if [[ $UPDATE_BASELINE -eq 1 ]]; then
    {
        printf '# Per-doc snippet-skip budget — see the ratchet section of extract-snippets.sh.\n'
        printf '# path\tbare-no-build\ttotal-skipped\n'
        printf '%s' "$ratchet_rows" | LC_ALL=C sort
    } > "$BASELINE_FILE"
    echo "Wrote baseline: $BASELINE_FILE"
    exit 0
fi

if [[ $ratchet_failures -gt 0 ]]; then
    exit 2
fi

if [[ $total -eq 0 ]]; then
    echo "::error::No Swift snippets extracted from any gated doc or DocC catalog." >&2
    echo "If the docs intentionally dropped all code blocks, remove this gate." >&2
    exit 2
fi

exit 0
