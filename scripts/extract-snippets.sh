#!/usr/bin/env bash
# extract-snippets.sh — Extract fenced Swift code blocks from README.md and
# docs/QUICKSTART.md into standalone .swift files for downstream compilation.
#
# Wave D-C1 of the DX overhaul: the README's Hello World snippet is the
# single most important piece of copy-paste correctness in the repo. This
# script (plus its companion compile gate) makes "a future PR silently
# breaks the snippet" a CI failure rather than a Slack apology.
#
# What it does:
#   - Walks README.md and docs/QUICKSTART.md.
#   - Pulls out every fenced block tagged ```swift (case-insensitive).
#   - Numbers them per-file (readme-001.swift, quickstart-001.swift, ...).
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
#     `.target(` are heuristically classified as Package.swift fragments and
#     auto-skipped. These cannot be compiled standalone; their lint coverage
#     belongs to `scripts/check-readme.sh` (version-pin freshness).
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

INPUTS=(
    "README.md"
    "docs/QUICKSTART.md"
    "docs/QUICKSTART-CLI.md"
)

mkdir -p "$OUT_DIR"
# Clean any prior run so a deleted snippet doesn't linger as a stale file.
rm -f "$OUT_DIR"/readme-*.swift "$OUT_DIR"/quickstart-*.swift "$OUT_DIR"/quickstart-cli-*.swift \
      "$OUT_DIR"/readme-*.skip "$OUT_DIR"/quickstart-*.skip "$OUT_DIR"/quickstart-cli-*.skip 2>/dev/null || true

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

echo "Extracted ${total} Swift snippet(s) and skipped ${total_skipped} fragment(s) into ${OUT_DIR}"

if [[ $total -eq 0 ]]; then
    echo "::error::No Swift snippets extracted from README.md, docs/QUICKSTART.md, or docs/QUICKSTART-CLI.md." >&2
    echo "If the docs intentionally dropped all code blocks, remove this gate." >&2
    exit 2
fi

exit 0
