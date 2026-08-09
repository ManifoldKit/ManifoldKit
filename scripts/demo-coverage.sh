#!/usr/bin/env bash
# scripts/demo-coverage.sh
#
# The instrument milestone M0 of the demonstration program (issue #2453)
# reports through. Every ManifoldKit capability listed in
# scripts/demo-coverage-manifest.tsv is scored against three requirements:
#
#   R1  demonstrated by a runnable vehicle   (vehicle_kind != none)
#   R2  documented with a link that can't drift  (doc set AND the file exists)
#   R3  actually EXECUTED, not just labelled executed. lane must be one of
#       the executed lanes (per-pr, release-gate, live-e2e, weekly,
#       external — NOT "manual", NOT "none") AND exec_kind must be `live` or
#       `scripted` — NOT `compile`. A row whose lane fires per-pr but whose
#       invocation only compiles (e.g. `xcodebuild build-for-testing`, never
#       `test`) is NOT executed: nobody would notice the whole suite going
#       red. exec_kind is a promise about what the row's OWN lane_ref
#       actually does when it fires — read the workflow/script, don't infer.
#
# exec_kind (new column, between lane_ref and notes) is one of:
#   live      drives real backends/system (a real Ollama server, a real MCP
#             subprocess, a human doing ad hoc QA against the real app)
#   scripted  executes with scripted/mock backends (a UI test against canned
#             demo scenarios, a deterministic-lane golden-scenario replay)
#   compile   build-only — compiles/links but asserts nothing ever runs
#   (empty)   only valid when lane=none — nothing fires at all
#
# Modes:
#   scripts/demo-coverage.sh                  human scoreboard (stdout)
#   scripts/demo-coverage.sh --markdown FILE  same scoreboard, written as markdown
#   scripts/demo-coverage.sh --check          manifest integrity + no-regression ratchet
#   scripts/demo-coverage.sh --update-baseline   regenerate scripts/demo-coverage-baseline.tsv
#
# --manifest / --baseline (or the DEMO_COVERAGE_MANIFEST / DEMO_COVERAGE_BASELINE
# env vars) override the default paths — used by DemoCoverageGateAuditTest's
# sabotage tests, which point this script at a planted fixture tree rather
# than the real manifest/baseline.
#
# The ratchet baseline (scripts/demo-coverage-baseline.tsv) holds ONLY the
# per-row R1/R2/R3 states — NOT the aggregate public-type-coverage percentage.
# That percentage is reported in the scoreboard as an informational signal but
# deliberately is NOT ratcheted: it legitimately moves in both directions for
# reasons that have nothing to do with a demo-coverage regression (deleting an
# undemonstrated public type raises it; adding one new public type anywhere in
# the package lowers it, e.g. 104/910 -> 104/911), so gating on it would
# produce a false red on an unrelated PR that merely adds API surface, and
# every routine `--update-baseline` call would silently re-baseline away the
# "regression" it just caused — neutering the ratchet rather than enforcing it.
#
# One scoring implementation: `current_state` is the ONLY place R1/R2/R3 are
# computed. --check and both scoreboard renderers all consume its output and
# only format — so the markdown scoreboard (the milestone's reporting
# artifact) can never disagree with what the gate itself enforces.
#
# Bash 3.2 compatible (CI runners) — no `declare -A`, no `mapfile`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="scoreboard"
MARKDOWN_OUT=""
MANIFEST_OVERRIDE=""
BASELINE_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: demo-coverage.sh [--markdown FILE] [--manifest FILE] [--baseline FILE]
       demo-coverage.sh --check [--manifest FILE] [--baseline FILE]
       demo-coverage.sh --update-baseline [--manifest FILE] [--baseline FILE]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            MODE="check"
            shift
            ;;
        --update-baseline)
            MODE="update-baseline"
            shift
            ;;
        --markdown)
            MARKDOWN_OUT="${2:-}"
            shift 2
            ;;
        --manifest)
            MANIFEST_OVERRIDE="${2:-}"
            shift 2
            ;;
        --baseline)
            BASELINE_OVERRIDE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

MANIFEST="${MANIFEST_OVERRIDE:-${DEMO_COVERAGE_MANIFEST:-$REPO_ROOT/scripts/demo-coverage-manifest.tsv}}"
BASELINE="${BASELINE_OVERRIDE:-${DEMO_COVERAGE_BASELINE:-$REPO_ROOT/scripts/demo-coverage-baseline.tsv}}"
TYPES_SCRIPT="$REPO_ROOT/scripts/_lib/demo-coverage-types.py"
API_BASELINE_DIR="$REPO_ROOT/Tests/APIFreezeTests/api-surface-baseline"
EXAMPLE_ROOT="$REPO_ROOT/Example"

EXPECTED_HEADER=$'id\ttitle\tproducts\tvehicle_kind\tvehicle_path\tdoc\tlane\tlane_ref\texec_kind\tnotes'
EXPECTED_COLUMN_COUNT=10
VALID_VEHICLE_KINDS="example-app focused-example script scenario external none"
VALID_LANES="per-pr release-gate live-e2e weekly manual external none"
VALID_EXEC_KINDS="live scripted compile"
# R3 ("actually executed") requires BOTH: lane is one of these lanes, AND
# exec_kind is live or scripted (never compile) — see the header comment.
EXECUTED_LANES="per-pr release-gate live-e2e weekly external"
EXECUTED_EXEC_KINDS="live scripted"
# lane_ref values are free text UNLESS they look like a path (contain `/` or
# end in .yml/.swift/.sh), in which case they are a promise the file exists —
# see check_manifest_integrity's lane_ref loop and docs/DEMO-COVERAGE.md's
# "lane_ref convention" section. manual/external rows are exempt: their
# lane_ref is routinely prose ("manual QA — no named script/test",
# "companion CI") that can legitimately contain a `/` (e.g. "script/test")
# without being a path promise at all.
PATH_EXEMPT_LANES="manual external"

if [[ ! -f "$MANIFEST" ]]; then
    echo "demo-coverage.sh: manifest not found: $MANIFEST" >&2
    exit 1
fi

in_list() {
    # $1: needle, $2: space-separated haystack
    local needle="$1" haystack="$2" item
    for item in $haystack; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

is_path_shaped() {
    # $1: a single (trimmed) lane_ref element. True if it looks like a path
    # promise rather than free text.
    local candidate="$1"
    case "$candidate" in
        */*) return 0 ;;
        *.yml|*.swift|*.sh) return 0 ;;
        *) return 1 ;;
    esac
}

count_tabs() {
    # $1: a raw line. Echoes the number of literal tab characters in it.
    printf '%s' "$1" | tr -cd '\t' | wc -c | tr -d ' '
}

# ---- Manifest integrity (part a of --check; also run before every mode so ----
# ---- the scoreboard and --update-baseline never operate on a malformed sheet.)
INTEGRITY_VIOLATIONS=""

add_integrity_violation() {
    INTEGRITY_VIOLATIONS="${INTEGRITY_VIOLATIONS}$1
"
}

check_manifest_integrity() {
    local actual_header
    actual_header="$(head -n 1 "$MANIFEST")"
    if [[ "$actual_header" != "$EXPECTED_HEADER" ]]; then
        add_integrity_violation "header: expected exactly the ${EXPECTED_COLUMN_COUNT}-column TSV header, got: $actual_header"
    fi

    local dup_ids
    dup_ids="$(tail -n +2 "$MANIFEST" | cut -f1 | sort | uniq -d)"
    if [[ -n "$dup_ids" ]]; then
        local dup
        while IFS= read -r dup; do
            [[ -n "$dup" ]] && add_integrity_violation "duplicate id: $dup"
        done <<< "$dup_ids"
    fi

    # Column-count check FIRST, on the raw (untranslated) line: `read` with
    # exactly EXPECTED_COLUMN_COUNT variables silently folds any extra
    # trailing columns into the last one (`notes`) and leaves missing
    # trailing columns empty — neither is an error `read` itself reports, so
    # a row with a mis-placed tab could quietly corrupt every field after it
    # with nothing but a garbled `notes` cell to notice. Count tabs directly.
    local raw_line raw_id tab_count
    while IFS= read -r raw_line; do
        [[ -z "$raw_line" ]] && continue
        tab_count="$(count_tabs "$raw_line")"
        if [[ "$tab_count" -ne $((EXPECTED_COLUMN_COUNT - 1)) ]]; then
            raw_id="${raw_line%%$'\t'*}"
            add_integrity_violation "$raw_id: expected $EXPECTED_COLUMN_COUNT tab-separated columns, got $((tab_count + 1))"
        fi
    done < <(tail -n +2 "$MANIFEST")

    local id title products vehicle_kind vehicle_path doc lane lane_ref exec_kind notes
    while IFS=$'\036' read -r id title products vehicle_kind vehicle_path doc lane lane_ref exec_kind notes; do
        [[ -z "$id" ]] && continue

        # `title` is the only column with no other constraint that would
        # catch an empty value — every other column is either required
        # non-empty (checked below) or legitimately blank. An empty title
        # is also the one shape that can trip the tab-is-IFS-whitespace
        # collapse bug (see current_state's RS-delimited output below) if
        # this check ever regresses, so it doubles as a canary for that class.
        if [[ -z "$title" ]]; then
            add_integrity_violation "$id: title is empty"
        fi

        if ! in_list "$vehicle_kind" "$VALID_VEHICLE_KINDS"; then
            add_integrity_violation "$id: invalid vehicle_kind '$vehicle_kind'"
        fi
        if ! in_list "$lane" "$VALID_LANES"; then
            add_integrity_violation "$id: invalid lane '$lane'"
        fi

        if [[ -n "$vehicle_path" && ! -e "$REPO_ROOT/$vehicle_path" ]]; then
            add_integrity_violation "$id: vehicle_path does not exist: $vehicle_path"
        fi
        if [[ -n "$doc" && ! -e "$REPO_ROOT/$doc" ]]; then
            add_integrity_violation "$id: doc does not exist: $doc"
        fi
        # A doc is not a runnable vehicle — vehicle_path pointing at the
        # exact same file as doc is always a mistake (the app-eval row's
        # original defect: vehicle_path=doc=docs/APP-EVAL.md, silently
        # claiming a documentation page as its own demo vehicle).
        if [[ -n "$vehicle_path" && "$vehicle_path" == "$doc" ]]; then
            add_integrity_violation "$id: vehicle_path equals doc ('$vehicle_path') — a doc is not a runnable vehicle"
        fi

        if [[ "$lane" == "none" && -n "$lane_ref" ]]; then
            add_integrity_violation "$id: lane is 'none' but lane_ref is set ('$lane_ref')"
        fi
        if [[ "$lane" != "none" && -z "$lane_ref" ]]; then
            add_integrity_violation "$id: lane is '$lane' but lane_ref is empty"
        fi

        # exec_kind: valid enum (when set), empty iff lane=none, and a
        # `compile` row must carry a note saying where real execution would
        # come from (or "-" if there's no path to it today).
        if [[ "$lane" == "none" && -n "$exec_kind" ]]; then
            add_integrity_violation "$id: lane is 'none' but exec_kind is set ('$exec_kind')"
        fi
        if [[ "$lane" != "none" && -z "$exec_kind" ]]; then
            add_integrity_violation "$id: lane is '$lane' but exec_kind is empty"
        fi
        if [[ -n "$exec_kind" ]] && ! in_list "$exec_kind" "$VALID_EXEC_KINDS"; then
            add_integrity_violation "$id: invalid exec_kind '$exec_kind'"
        fi
        if [[ "$exec_kind" == "compile" && -z "$notes" ]]; then
            add_integrity_violation "$id: exec_kind is 'compile' but notes is empty — say where real execution would come from (or '-')"
        fi

        # Path-shaped lane_ref elements are a promise the file exists, unless
        # the lane is manual/external (where lane_ref is routinely prose).
        if [[ -n "$lane_ref" ]] && ! in_list "$lane" "$PATH_EXEMPT_LANES"; then
            local old_ifs="$IFS" elem
            IFS=','
            for elem in $lane_ref; do
                IFS="$old_ifs"
                elem="$(echo "$elem" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if is_path_shaped "$elem" && [[ ! -e "$REPO_ROOT/$elem" ]]; then
                    add_integrity_violation "$id: lane_ref element does not exist: $elem"
                fi
            done
            IFS="$old_ifs"
        fi
    done < <(tail -n +2 "$MANIFEST" | tr '\t' '\036')
}

check_manifest_integrity

if [[ -n "$INTEGRITY_VIOLATIONS" ]]; then
    echo "demo-coverage.sh: manifest integrity violations in $MANIFEST:" >&2
    echo "$INTEGRITY_VIOLATIONS" | while IFS= read -r line; do
        [[ -n "$line" ]] && echo "  - $line" >&2
    done
    exit 1
fi

# ---- Current-state computation — the ONLY place R1/R2/R3 are scored -------
#
# Emits "id<RS>title<RS>lane<RS>r1<RS>r2<RS>r3" (RS = \036) for every manifest
# row, in manifest order. --check, the text scoreboard, and the markdown
# scoreboard all read THIS output rather than re-deriving the flags
# themselves. RS, not a literal tab: bash's `IFS=$'\t' read` treats tab as
# "IFS whitespace" and COLLAPSES CONSECUTIVE tabs regardless of what else is
# in IFS — verified directly against /bin/bash 3.2 (the manifest read below
# hit this same bug first; see commit 4a1c8421). id/lane/r1/r2/r3 are all
# guaranteed non-empty by check_manifest_integrity (which always runs first),
# but `title` had no such guarantee until the check just above was added —
# an empty title would have silently shifted every field after it one
# column left in a tab-delimited pipe, corrupting the R3 a caller reads
# while leaving `--check`'s OWN internal comparison (which never round-trips
# through this function's raw output — see run_check) unaffected. RS avoids
# the whole class, defense-in-depth on top of the title-non-empty check.

current_state() {
    local id title products vehicle_kind vehicle_path doc lane lane_ref exec_kind notes
    while IFS=$'\036' read -r id title products vehicle_kind vehicle_path doc lane lane_ref exec_kind notes; do
        [[ -z "$id" ]] && continue
        local r1=0 r2=0 r3=0
        [[ "$vehicle_kind" != "none" ]] && r1=1
        [[ -n "$doc" && -e "$REPO_ROOT/$doc" ]] && r2=1
        if in_list "$lane" "$EXECUTED_LANES" && in_list "$exec_kind" "$EXECUTED_EXEC_KINDS"; then
            r3=1
        fi
        printf '%s\036%s\036%s\036%s\036%s\036%s\n' "$id" "$title" "$lane" "$r1" "$r2" "$r3"
    done < <(tail -n +2 "$MANIFEST" | tr '\t' '\036')
}

# ---- Type-coverage table (module\ttotal\tnamed, plus a TOTAL line) ----
# Informational only — see the header comment for why this is NOT ratcheted.
# NOTE: --check never calls this — it only reads current_state's R1/R2/R3
# output, so a type-coverage-helper failure can never affect --check or its
# sabotage fixtures. Only the scoreboard (default / --markdown) renders it.

type_coverage_table() {
    python3 "$TYPES_SCRIPT" "$API_BASELINE_DIR" "$EXAMPLE_ROOT"
}

# ================================= --check =================================

run_check() {
    if [[ ! -f "$BASELINE" ]]; then
        echo "demo-coverage.sh --check: baseline not found: $BASELINE (run --update-baseline first)" >&2
        exit 1
    fi

    local violations=""
    add_violation() { violations="${violations}$1
"; }

    # Not `local`: the cleanup trap fires at script EXIT, after this function
    # has already returned and its locals have gone out of scope — `set -u`
    # would then fault on an unbound variable. Global scope keeps them live.
    CURRENT_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/demo-coverage-current.XXXXXX")"
    trap 'rm -f "$CURRENT_STATE_FILE"' EXIT
    local current_file="$CURRENT_STATE_FILE"

    # id/r1/r2/r3 only — cut past current_state's title/lane display columns
    # so the shape matches the baseline file exactly. current_state's raw
    # output is RS-delimited (see its own header comment); cut on RS, then
    # convert back to real tabs — id/r1/r2/r3 are always non-empty, so the
    # collapse bug that motivated RS in the first place cannot recur here.
    current_state | cut -d $'\036' -f1,4,5,6 | tr '\036' '\t' > "$current_file"

    # Baseline rows: every id present in the baseline must still exist in the
    # current manifest, and none of R1/R2/R3 may regress from 1 (met) to 0
    # (unmet). New ids (not in baseline) are allowed.
    local bid br1 br2 br3
    while IFS=$'\t' read -r bid br1 br2 br3; do
        [[ -z "$bid" ]] && continue
        local cur_line
        cur_line="$(grep -m1 "^${bid}"$'\t' "$current_file" || true)"
        if [[ -z "$cur_line" ]]; then
            add_violation "$bid: present in baseline but missing from current manifest (capability dropped silently)"
            continue
        fi
        local cid cr1 cr2 cr3
        IFS=$'\t' read -r cid cr1 cr2 cr3 <<< "$cur_line"
        if [[ "$br1" == "1" && "$cr1" == "0" ]]; then
            add_violation "$bid: R1 regressed (had a vehicle in baseline, now vehicle_kind=none)"
        fi
        if [[ "$br2" == "1" && "$cr2" == "0" ]]; then
            add_violation "$bid: R2 regressed (doc existed in baseline, now missing/unset)"
        fi
        if [[ "$br3" == "1" && "$cr3" == "0" ]]; then
            add_violation "$bid: R3 regressed (was executed in baseline — lane in $EXECUTED_LANES with exec_kind in $EXECUTED_EXEC_KINDS — no longer)"
        fi
    done < <(tail -n +2 "$BASELINE")

    if [[ -n "$violations" ]]; then
        echo "demo-coverage.sh --check: ratchet violations (current vs $BASELINE):" >&2
        echo "$violations" | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  - $line" >&2
        done
        exit 1
    fi

    echo "demo-coverage.sh --check: OK — manifest integrity clean, no ratchet regressions vs $BASELINE"
}

# ============================ --update-baseline =============================

run_update_baseline() {
    {
        echo "id	r1	r2	r3"
        current_state | cut -d $'\036' -f1,4,5,6 | tr '\036' '\t'
    } > "$BASELINE"
    echo "demo-coverage.sh --update-baseline: wrote $BASELINE"
}

# ================================ scoreboard ================================
#
# Both renderers below consume current_state's output for the R1/R2/R3 flags
# and the manual-only count — they format, they do not re-derive scoring.

render_scoreboard_text() {
    local total=0 r1_pass=0 r2_pass=0 r3_pass=0 manual_only=0
    local id title lane r1 r2 r3
    echo "=== ManifoldKit demo coverage scoreboard (M0, issue #2453) ==="
    echo ""
    printf '%-28s %-3s %-3s %-3s  %s\n' "ID" "R1" "R2" "R3" "TITLE"
    while IFS=$'\036' read -r id title lane r1 r2 r3; do
        [[ -z "$id" ]] && continue
        total=$((total + 1))
        [[ "$r1" == "1" ]] && r1_pass=$((r1_pass + 1))
        [[ "$r2" == "1" ]] && r2_pass=$((r2_pass + 1))
        [[ "$r3" == "1" ]] && r3_pass=$((r3_pass + 1))
        [[ "$lane" == "manual" ]] && manual_only=$((manual_only + 1))
        local d1 d2 d3
        d1=$([[ "$r1" == "1" ]] && echo "v" || echo ".")
        d2=$([[ "$r2" == "1" ]] && echo "v" || echo ".")
        d3=$([[ "$r3" == "1" ]] && echo "v" || echo ".")
        printf '%-28s %-3s %-3s %-3s  %s\n' "$id" "$d1" "$d2" "$d3" "$title"
    done < <(current_state)
    echo ""
    echo "Summary: $total capabilities — R1 (vehicle): $r1_pass/$total, R2 (doc): $r2_pass/$total, R3 (executed): $r3_pass/$total"
    echo "  ($manual_only row(s) are lane=manual — a human can run them, but R3 counts live/scripted execution only, never manual or compile-only.)"
    echo ""
    echo "=== Public-type coverage (informational only — not ratcheted; see script header) ==="
    echo ""
    local type_table_output
    if ! type_table_output="$(type_coverage_table)"; then
        echo "demo-coverage.sh: type-coverage helper failed — see stderr above" >&2
        exit 1
    fi
    printf '%-32s %8s %8s %6s\n' "MODULE" "TOTAL" "NAMED" "PCT"
    local mod mtotal mnamed
    while IFS=$'\t' read -r mod mtotal mnamed; do
        [[ -z "$mod" ]] && continue
        local pct=0
        if [[ "$mtotal" -gt 0 ]]; then pct=$(( mnamed * 100 / mtotal )); fi
        printf '%-32s %8s %8s %5s%%\n' "$mod" "$mtotal" "$mnamed" "$pct"
    done <<< "$type_table_output"
}

render_scoreboard_markdown() {
    local total=0 r1_pass=0 r2_pass=0 r3_pass=0 manual_only=0
    local id title lane r1 r2 r3
    echo "# ManifoldKit demo coverage scoreboard (M0, issue #2453)"
    echo ""
    echo "| id | R1 | R2 | R3 | title |"
    echo "|---|---|---|---|---|"
    while IFS=$'\036' read -r id title lane r1 r2 r3; do
        [[ -z "$id" ]] && continue
        total=$((total + 1))
        [[ "$r1" == "1" ]] && r1_pass=$((r1_pass + 1))
        [[ "$r2" == "1" ]] && r2_pass=$((r2_pass + 1))
        [[ "$r3" == "1" ]] && r3_pass=$((r3_pass + 1))
        [[ "$lane" == "manual" ]] && manual_only=$((manual_only + 1))
        local d1 d2 d3
        d1=$([[ "$r1" == "1" ]] && echo "v" || echo "-")
        d2=$([[ "$r2" == "1" ]] && echo "v" || echo "-")
        d3=$([[ "$r3" == "1" ]] && echo "v" || echo "-")
        echo "| $id | $d1 | $d2 | $d3 | $title |"
    done < <(current_state)
    echo ""
    echo "Summary: $total capabilities — R1 (vehicle): $r1_pass/$total, R2 (doc): $r2_pass/$total, R3 (executed): $r3_pass/$total"
    echo ""
    echo "($manual_only row(s) are lane=manual — a human can run them, but R3 counts live/scripted execution only, never manual or compile-only.)"
    echo ""
    echo "## Public-type coverage (informational only — not ratcheted)"
    echo ""
    local type_table_output
    if ! type_table_output="$(type_coverage_table)"; then
        echo "demo-coverage.sh: type-coverage helper failed — see stderr above" >&2
        exit 1
    fi
    echo "| module | total | named | pct |"
    echo "|---|---|---|---|"
    local mod mtotal mnamed
    while IFS=$'\t' read -r mod mtotal mnamed; do
        [[ -z "$mod" ]] && continue
        local pct=0
        if [[ "$mtotal" -gt 0 ]]; then pct=$(( mnamed * 100 / mtotal )); fi
        echo "| $mod | $mtotal | $mnamed | ${pct}% |"
    done <<< "$type_table_output"
}

case "$MODE" in
    check)
        run_check
        ;;
    update-baseline)
        run_update_baseline
        ;;
    scoreboard)
        if [[ -n "$MARKDOWN_OUT" ]]; then
            render_scoreboard_markdown > "$MARKDOWN_OUT"
            echo "demo-coverage.sh: wrote markdown scoreboard to $MARKDOWN_OUT"
        else
            render_scoreboard_text
        fi
        ;;
esac
