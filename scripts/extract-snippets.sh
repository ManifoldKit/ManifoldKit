#!/usr/bin/env bash
# extract-snippets.sh — Extract fenced Swift code blocks from README.md,
# docs/QUICKSTART*.md, docs/WHY-MANIFOLDKIT.md, and DocC catalogs into
# standalone .swift files for downstream compilation.
#
# Wave D-C1 of the DX overhaul: the README's Hello World snippet is the
# single most important piece of copy-paste correctness in the repo. This
# script (plus its companion compile gate) makes "a future PR silently
# breaks the snippet" a CI failure rather than a Slack apology.
#
# DocC coverage (added 2026-05-23 in response to A2-F8): in addition to the
# README/QUICKSTART files, the script walks every `Sources/*/Documentation.docc/`
# Markdown file (including nested `Articles/` and `Extensions/` directories).
# DocC articles are documentation and are subject to the same compile-test
# policy — A2-F8 was a broken `BuildingAChatUI.md` snippet that the
# README/QUICKSTART-scoped gate could not see. Extracted DocC blocks use the
# label `docc-<module>-<filename>-<NNN>` so test output is greppable per
# article.
#
# What it does:
#   - Walks README.md, docs/QUICKSTART*.md, and every Markdown file inside
#     a `.docc/` directory under `Sources/`.
#   - Pulls out every fenced block tagged ```swift (case-insensitive).
#   - Numbers them per-file (readme-001.swift, quickstart-001.swift,
#     docc-manifoldui-buildingachatui-001.swift, ...).
#   - Writes each to --out <dir> (default /tmp/manifoldkit-snippets) with a
#     `// Source: <relative-path>:<line>` header so failures point back to docs.
#
# Skip / include policy:
#   - Blocks fenced as ```swift,no-build (or any ```swift* containing the
#     literal token "no-build") are recorded with a `.skip` marker file
#     instead of a `.swift` file. Use this sparingly — placeholder snippets
#     with `/* ... */` or undefined identifiers, Package.swift fragments that
#     a consumer must paste into their own manifest, etc. The Hello World
#     snippet MUST never carry no-build.
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
#   2 — zero Swift blocks found across all inputs (defensive — if every
#       snippet vanished we want a loud signal, not silent success).
#
# Portability: BSD awk/sed/grep only (macOS default toolchain). No grep -P.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="/tmp/manifoldkit-snippets"
VERBOSE=0

usage() {
    cat <<EOF
Usage: $0 [--out <dir>] [--verbose]

Options:
  --out <dir>     Output directory (default: /tmp/manifoldkit-snippets).
  --verbose       Log each extracted block to stderr.
  -h, --help      Show this help.
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

# Every docs/QUICKSTART-*.md is swept (not just the high-level ones): a doc with
# no compile gate drifts silently. Blocks needing a module the gate does not
# build (ManifoldVoice in VOICE) are tagged ```swift,no-build``` in the doc;
# package-manifest fragments (APPINTENTS) auto-skip via the .package/.target
# heuristic. The workflow `paths:` filter globs docs/QUICKSTART*.md to match.
# IMAGE-GEN/VIDEO-GEN quickstarts moved to the manifold-mlx companion package
# with the MLX family in v0.48 PR C2.
INPUTS=(
    "README.md"
    "docs/QUICKSTART.md"
    "docs/QUICKSTART-CLI.md"
    "docs/QUICKSTART-RAG.md"
    "docs/QUICKSTART-BRING-YOUR-OWN-UI.md"
    "docs/QUICKSTART-MODEL-SELECTION.md"
    "docs/QUICKSTART-TOOLS.md"
    "docs/QUICKSTART-APPINTENTS.md"
    "docs/QUICKSTART-VOICE.md"
    "docs/WHY-MANIFOLDKIT.md"
)

mkdir -p "$OUT_DIR"
# Clean any prior run so a deleted snippet doesn't linger as a stale file.
# Includes docc-* prefixes added in the 2026-05-23 DocC extension and the
# why-* / quickstart-rag-* prefixes added in the 0.45 front-door pass.
# (quickstart-rag-* is also caught by the quickstart-* glob, but list it
# explicitly so intent survives a future glob change.)
rm -f "$OUT_DIR"/readme-*.swift "$OUT_DIR"/quickstart-*.swift "$OUT_DIR"/quickstart-cli-*.swift \
      "$OUT_DIR"/quickstart-rag-*.swift "$OUT_DIR"/why-*.swift \
      "$OUT_DIR"/docc-*.swift \
      "$OUT_DIR"/readme-*.skip "$OUT_DIR"/quickstart-*.skip "$OUT_DIR"/quickstart-cli-*.skip \
      "$OUT_DIR"/quickstart-rag-*.skip "$OUT_DIR"/why-*.skip \
      "$OUT_DIR"/docc-*.skip 2>/dev/null || true

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
                case "$cur_tag" in
                    *no-build*)
                        skip_reason="explicit-no-build-tag"
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

extract_one "README.md" "readme"
extract_one "docs/QUICKSTART.md" "quickstart"
extract_one "docs/QUICKSTART-CLI.md" "quickstart-cli"
extract_one "docs/QUICKSTART-RAG.md" "quickstart-rag"
extract_one "docs/QUICKSTART-BRING-YOUR-OWN-UI.md" "quickstart-byo-ui"
extract_one "docs/QUICKSTART-MODEL-SELECTION.md" "quickstart-model-selection"
extract_one "docs/QUICKSTART-TOOLS.md" "quickstart-tools"
extract_one "docs/QUICKSTART-APPINTENTS.md" "quickstart-appintents"
extract_one "docs/QUICKSTART-VOICE.md" "quickstart-voice"
extract_one "docs/WHY-MANIFOLDKIT.md" "why"

# DocC catalogs. Walk every Markdown file inside any Sources/*/Documentation.docc/
# directory (including nested Articles/, Extensions/, etc.). Slug pattern is
# `docc-<module>-<filename>` (both lowercased) so test output stays greppable
# per-article. `find` is used for portability — BSD find on macOS supports
# `-path` with shell globbing.
docc_files=()
while IFS= read -r path; do
    [[ -n "$path" ]] && docc_files+=("$path")
done < <(cd "$REPO_ROOT" && find Sources -type f -name '*.md' -path '*/*.docc/*' 2>/dev/null | LC_ALL=C sort)

for docc_rel in "${docc_files[@]}"; do
    # Derive module name from the .docc directory: Sources/<Module>/<Module>.docc/...
    # Take everything up to ".docc" then strip the last path component to get the
    # module name. Example:
    #   Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md
    #     module = ManifoldUI, file = BuildingAChatUI
    module_path="${docc_rel%%.docc/*}"          # Sources/ManifoldUI/ManifoldUI
    module_name="${module_path##*/}"            # ManifoldUI
    file_base="$(basename "$docc_rel" .md)"     # BuildingAChatUI
    # Lowercase for the slug (BSD tr).
    module_lc=$(printf '%s' "$module_name" | tr '[:upper:]' '[:lower:]')
    file_lc=$(printf '%s' "$file_base" | tr '[:upper:]' '[:lower:]')
    slug="docc-${module_lc}-${file_lc}"
    extract_one "$docc_rel" "$slug"
done

echo "Extracted ${total} Swift snippet(s) and skipped ${total_skipped} fragment(s) into ${OUT_DIR}"

if [[ $total -eq 0 ]]; then
    echo "::error::No Swift snippets extracted from README.md, docs/QUICKSTART*.md, or any DocC catalog." >&2
    echo "If the docs intentionally dropped all code blocks, remove this gate." >&2
    exit 2
fi

exit 0
