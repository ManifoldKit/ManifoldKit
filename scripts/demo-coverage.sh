#!/usr/bin/env bash
# scripts/demo-coverage.sh
#
# The instrument milestone M0 of the demonstration program (issue #2453)
# reports through. Every ManifoldKit capability listed in
# scripts/demo-coverage-manifest.tsv is scored against three requirements:
#
#   R1  demonstrated by a runnable vehicle   (vehicle_kind != none)
#   R2  documented with a link that can't drift  (doc set AND the file exists)
#   R3  a declared execution route, not just a labelled one — method-bound
#       where the lane is a test. lane must be one of the executed lanes
#       (per-pr, release-gate, live-e2e, weekly, external — NOT "manual",
#       NOT "none") AND exec_kind must be `live` or `scripted` — NOT
#       `compile`. A row whose lane fires per-pr but whose invocation only
#       compiles (e.g. `xcodebuild build-for-testing`, never `test`) is NOT
#       executed: nobody would notice the whole suite going red. exec_kind is
#       a promise about what the row's OWN lane_ref actually does when it
#       fires — read the workflow/script, don't infer. Where the lane names a
#       test file or workflow, `lane_methods` binds R3 to the exact method(s)
#       that exercise the capability — see below. R3 does NOT assert the lane
#       ran recently or is currently green; last-run/staleness evidence is a
#       later milestone (M5).
#
# exec_kind (column between lane_ref/lane_methods and notes) is one of:
#   live      drives real backends/system (a real Ollama server, a real MCP
#             subprocess, a human doing ad hoc QA against the real app)
#   scripted  executes with scripted/mock backends (a UI test against canned
#             demo scenarios, a deterministic-lane golden-scenario replay)
#   compile   build-only — compiles/links but asserts nothing ever runs
#   (empty)   only valid when lane=none — nothing fires at all
#
# lane_methods (column between lane_ref and exec_kind) is a comma-separated
# list of "Suite/method" entries — the exact XCTest methods that exercise the
# capability, for rows whose lane_ref names a test file or a workflow that
# runs named methods. Empty is allowed for non-test lanes (a generic script, a
# companion/external CI system this repo can't see into, prose-manual QA).
# Required (non-empty) when exec_kind is live|scripted AND lane_ref contains a
# bare `.swift` test-file path — see check_manifest_integrity. A "Suite" name
# resolves against the row's OWN lane_ref first (any bare `.swift` element
# whose basename matches), then falls back to the historical
# Example/AdvancedUITests/<Suite>.swift convention — see
# resolve_lane_method_suite_file. A workflow lane_ref is checked two ways
# depending on where the suite resolved: an Example/AdvancedUITests/* suite
# must appear in the workflow's exact `-only-testing:AdvancedUITests/Suite/
# method` list; any other suite (e.g. Tests/**) must be reachable through a
# `--filter <pattern>` argument in the workflow that matches "Suite/method"
# as a substring (the real semantics of `swift test --filter`/`scripts/
# test.sh --filter`, which is a regex over the qualified test name, not an
# exact list) — matched against the full "Suite/method" pair, not just
# Suite, so a filter naming one method doesn't also bind every other method
# in the same suite. A non-UI-test workflow is ALSO checked for a `--skip
# <pattern>` argument that would exclude the claimed Suite/method from an
# already-`--filter`-matched set; an unparseable --skip value (quoted,
# `--skip=value`, or a regex starting with punctuation — the extraction
# regex only understands a bare unquoted identifier after `--skip `) fails
# closed with a named "cannot verify" violation rather than silently
# passing, the same discipline check_product_completeness's own
# extraction-regex guard uses below. (Known, deliberately unfixed parallel
# gap: xcodebuild's `-only-testing:` path is checked above only for
# presence in the workflow, never for a co-occurring `-skip-testing:`
# argument that could exclude the same Suite/method — no manifest row's
# lane_ref uses `-skip-testing:` today, so there is no current exposure.)
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
# than the real manifest/baseline. The product-completeness audit (see
# check_product_completeness) reads $REPO_ROOT/Package.swift and
# $REPO_ROOT/scripts/demo-coverage-product-allowlist.txt directly — a sabotage
# fixture that wants to exercise it plants its own Package.swift at the
# fixture root (REPO_ROOT resolves there once demo-coverage.sh is copied in);
# a fixture that doesn't create one skips the audit entirely (see the
# function), so it never affects sabotage tests unrelated to it.
#
# The ratchet baseline (scripts/demo-coverage-baseline.tsv) holds ONLY the
# per-row R1/R2/R3 states — NOT the aggregate lexical-public-type-mentions
# percentage. That percentage is reported in the scoreboard as an
# informational signal but deliberately is NOT ratcheted: it legitimately
# moves in both directions for reasons that have nothing to do with a demo-
# coverage regression (deleting an unmentioned public type raises it; adding
# one new public type anywhere in the package lowers it, e.g. 104/910 ->
# 104/911), so gating on it would produce a false red on an unrelated PR that
# merely adds API surface, and every routine `--update-baseline` call would
# silently re-baseline away the "regression" it just caused — neutering the
# ratchet rather than enforcing it. The ratchet's actual job, precisely
# stated: prevent an UNACCOMPANIED regression — an R1/R2/R3 flag flipping
# from met to unmet with no corresponding manifest edit acknowledging it.
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
PACKAGE_SWIFT="$REPO_ROOT/Package.swift"
PRODUCT_ALLOWLIST="$REPO_ROOT/scripts/demo-coverage-product-allowlist.txt"
# Default/fallback convention for lane_methods "Suite/method" resolution: a
# suite named with no matching bare .swift element in the row's OWN lane_ref
# (see resolve_lane_method_suite_file) is assumed to live here — true for
# every UI-test-bound row, none of which lists its own suite file in lane_ref.
# A row whose tests live elsewhere (e.g. Tests/**) names its suite file
# directly in lane_ref instead; resolve_lane_method_suite_file tries that
# first.
UI_TEST_SUITE_DIR="$REPO_ROOT/Example/AdvancedUITests"

EXPECTED_HEADER=$'id\ttitle\tproducts\tvehicle_kind\tvehicle_path\tdoc\tlane\tlane_ref\tlane_methods\texec_kind\tnotes'
EXPECTED_COLUMN_COUNT=11
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

comma_list_elements() {
    # $1: a comma-separated value. Prints each trimmed, non-empty element on
    # its own line. Shared by lane_ref, lane_methods, and products parsing —
    # tab is unsafe as an internal delimiter here (see current_state's header
    # comment for the bash IFS-whitespace collapse bug this sidesteps), but
    # comma is not "IFS whitespace" so plain `IFS=',' for` splitting is safe.
    local value="$1" old_ifs="$IFS" elem
    IFS=','
    for elem in $value; do
        IFS="$old_ifs"
        elem="$(echo "$elem" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "$elem" ]] && printf '%s\n' "$elem"
    done
    IFS="$old_ifs"
}

resolve_lane_method_suite_file() {
    # $1: a row's raw lane_ref, $2: a lane_methods "Suite" name (no extension).
    # Prints the repo-relative suite-file path a lane_methods entry's "Suite"
    # should resolve to, on stdout, and returns 0 — or returns 1 with no
    # output if it can't be resolved.
    #
    # Preferred: a bare `.swift` element in the row's OWN lane_ref whose
    # basename (sans extension) matches Suite exactly — this is the general
    # case, so a capability whose tests live outside Example/AdvancedUITests
    # (e.g. an XCTest under Tests/) can still be method-bound (#2453 M3,
    # toolschema-macro). Fallback: the historical hardcoded UI_TEST_SUITE_DIR
    # convention, kept so every pre-existing UI-test row — which never lists
    # its own suite file in lane_ref (see chat-ui/theming/tool-calling/
    # appintents above) — keeps resolving exactly as before.
    local lane_ref="$1" suite="$2" elem
    while IFS= read -r elem; do
        case "$elem" in
            *.swift)
                if [[ "$(basename "$elem" .swift)" == "$suite" ]]; then
                    printf '%s\n' "$elem"
                    return 0
                fi
                ;;
        esac
    done < <(comma_list_elements "$lane_ref")
    if [[ -e "$UI_TEST_SUITE_DIR/${suite}.swift" ]]; then
        printf '%s\n' "Example/AdvancedUITests/${suite}.swift"
        return 0
    fi
    return 1
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

    local id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes
    while IFS=$'\036' read -r id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes; do
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

        # lane_methods: forbidden when lane=none or exec_kind=compile (nothing
        # executes, so no method can be named); required when exec_kind is
        # live|scripted AND lane_ref names a bare .swift test file; when
        # present, every "Suite/method" entry must resolve to a real method in
        # a real suite file, and (for a workflow lane_ref) also appear in that
        # workflow's -only-testing list.
        if [[ "$lane" == "none" && -n "$lane_methods" ]]; then
            add_integrity_violation "$id: lane is 'none' but lane_methods is set ('$lane_methods')"
        fi
        if [[ "$exec_kind" == "compile" && -n "$lane_methods" ]]; then
            add_integrity_violation "$id: exec_kind is 'compile' but lane_methods is set ('$lane_methods') — nothing executes, so no method can be listed"
        fi

        if in_list "$exec_kind" "$EXECUTED_EXEC_KINDS"; then
            local lane_ref_has_swift=0 lr_elem_a
            while IFS= read -r lr_elem_a; do
                case "$lr_elem_a" in
                    *.swift) lane_ref_has_swift=1 ;;
                esac
            done < <(comma_list_elements "$lane_ref")
            if [[ "$lane_ref_has_swift" -eq 1 && -z "$lane_methods" ]]; then
                add_integrity_violation "$id: exec_kind is '$exec_kind' with a test-file lane_ref but lane_methods is empty"
            fi
        fi

        if [[ -n "$lane_methods" ]]; then
            local lm_entry
            while IFS= read -r lm_entry; do
                if [[ "$lm_entry" != */* ]]; then
                    add_integrity_violation "$id: lane_methods entry '$lm_entry' is not in 'Suite/method' form"
                    continue
                fi
                local lm_suite="${lm_entry%%/*}" lm_method="${lm_entry#*/}"
                if [[ -z "$lm_suite" || -z "$lm_method" ]]; then
                    add_integrity_violation "$id: lane_methods entry '$lm_entry' is not in 'Suite/method' form"
                    continue
                fi

                local suite_file_rel=""
                if ! suite_file_rel="$(resolve_lane_method_suite_file "$lane_ref" "$lm_suite")"; then
                    add_integrity_violation "$id: lane_methods entry '$lm_entry' names suite '${lm_suite}', which does not resolve to a suite file (checked lane_ref's own .swift path(s), then the Example/AdvancedUITests/${lm_suite}.swift default)"
                # Anchored so a commented-out declaration (`// func testFoo()`)
                # can't false-accept: an unanchored `grep -q "func X("` matches
                # a substring anywhere on the line, including inside a `//`
                # comment. Requires the `func` keyword to start the (optional
                # access-modifier-prefixed) declaration at the start of the
                # line, modulo leading whitespace.
                elif ! grep -qE "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?(public |package |internal |private )?func ${lm_method}\\(" "$REPO_ROOT/$suite_file_rel"; then
                    add_integrity_violation "$id: lane_methods entry '$lm_entry' — no 'func ${lm_method}(' found in ${suite_file_rel}"
                # Bare .swift lane_ref (not a workflow) is a stronger promise
                # than "this method exists somewhere in AdvancedUITests" — it
                # says THIS method lives in THIS suite file. Catch drift where
                # lane_methods names a real method that has since moved to a
                # different suite than the row's lane_ref claims. (Only
                # meaningful for the UI-test convention — a row that resolved
                # its suite file directly from its own lane_ref, per
                # resolve_lane_method_suite_file, can't drift from itself.)
                elif [[ -n "$lane_ref" ]]; then
                    local lr_elem_c lr_has_matching_bare_swift=0 lr_has_any_bare_swift=0
                    while IFS= read -r lr_elem_c; do
                        case "$lr_elem_c" in
                            */AdvancedUITests/*.swift)
                                lr_has_any_bare_swift=1
                                if [[ "$lr_elem_c" == */AdvancedUITests/${lm_suite}.swift ]]; then
                                    lr_has_matching_bare_swift=1
                                fi
                                ;;
                        esac
                    done < <(comma_list_elements "$lane_ref")
                    if [[ "$lr_has_any_bare_swift" -eq 1 && "$lr_has_matching_bare_swift" -eq 0 ]]; then
                        add_integrity_violation "$id: lane_methods entry '$lm_entry' names suite '${lm_suite}', which does not match the bare .swift file(s) in lane_ref ('$lane_ref')"
                    fi
                fi

                # If lane_ref names a workflow, the method must ALSO be
                # reachable through that workflow's invocation — otherwise
                # lane_methods could claim CI coverage the workflow doesn't
                # actually give it. Two shapes, because the invocation style
                # differs by suite location:
                #   - Example/AdvancedUITests/* suites run via xcodebuild's
                #     exact `-only-testing:AdvancedUITests/Suite/method`, so
                #     the workflow must name this exact Suite/method pair.
                #   - Any other suite (e.g. Tests/**) runs via `swift test
                #     --filter <pattern>` (scripts/test.sh's --filter is the
                #     same flag), whose pattern is a regex matched against the
                #     qualified name — a substring match, not an exact list —
                #     so the check is "does some --filter value in this
                #     workflow appear as a substring of Suite/method",
                #     matched against the full pair (not just Suite) so a
                #     filter naming one method can't also bind a sibling
                #     method in the same suite.
                local lr_elem_b
                while IFS= read -r lr_elem_b; do
                    case "$lr_elem_b" in
                        *.yml)
                            [[ -e "$REPO_ROOT/$lr_elem_b" ]] || continue
                            case "$suite_file_rel" in
                                Example/AdvancedUITests/*)
                                    if ! grep -q "AdvancedUITests/${lm_suite}/${lm_method}" "$REPO_ROOT/$lr_elem_b"; then
                                        add_integrity_violation "$id: lane_methods entry '$lm_entry' does not appear in ${lr_elem_b}'s -only-testing list"
                                    fi
                                    ;;
                                *)
                                    # The captured class includes `/` and the
                                    # match target is "$lm_suite/$lm_method"
                                    # (not just "$lm_suite") so a workflow
                                    # filter of "Suite/test_a" doesn't also
                                    # bind "Suite/test_b" — a bare `[A-Za-z0-9_]+`
                                    # capture truncated at the `/`, so any
                                    # method-scoped --filter value silently
                                    # matched every method in the suite.
                                    local wf_filter wf_filter_matched=0
                                    while IFS= read -r wf_filter; do
                                        if [[ -n "$wf_filter" && "${lm_suite}/${lm_method}" == *"$wf_filter"* ]]; then
                                            wf_filter_matched=1
                                            break
                                        fi
                                    done < <(grep -oE -- '--filter[[:space:]]+[A-Za-z0-9_/]+' "$REPO_ROOT/$lr_elem_b" | awk '{print $2}')
                                    if [[ "$wf_filter_matched" -eq 0 ]]; then
                                        add_integrity_violation "$id: lane_methods entry '$lm_entry' — ${lr_elem_b} has no --filter argument matching '${lm_suite}/${lm_method}'"
                                    fi
                                    # `swift test`/`scripts/test.sh` also
                                    # accept `--skip <pattern>`, which excludes
                                    # matches from an already-filtered set — a
                                    # matching --filter is not the whole story
                                    # if a --skip pattern also matches this
                                    # exact Suite/method.
                                    #
                                    # The value-extraction regex below only
                                    # parses a plain unquoted identifier
                                    # (`--skip test_a`) — it can't see a
                                    # quoted value (`--skip 'test_a'`/`--skip
                                    # "test_a"`), the `--skip=test_a` equals
                                    # form, or a regex value starting with
                                    # punctuation (`--skip .*test_a`). A
                                    # workflow using any of those would have a
                                    # real --skip argument that this check
                                    # can't parse, and treating "couldn't
                                    # parse" as "no --skip" is EXACTLY the
                                    # fail-open this whole mechanism exists to
                                    # close — the inverted-polarity mirror of
                                    # --filter's fail-CLOSED behavior above.
                                    # So: count `--skip` tokens (excluding
                                    # `--skip-update`, which has no
                                    # whitespace/`=` right after `skip`)
                                    # independently of what the
                                    # value-extraction regex can parse — the
                                    # same count-independently discipline
                                    # check_product_completeness uses above
                                    # for its own extraction regex. A
                                    # mismatch means an unparseable --skip
                                    # argument is present, so this fails
                                    # closed with a named error instead of
                                    # silently reporting clean.
                                    local wf_skip_token_count wf_skip_parsed_count
                                    # `|| true` inside the substitution (not
                                    # after it): under `set -euo pipefail`, a
                                    # workflow with NO --skip at all — the
                                    # common case — makes grep exit 1 with
                                    # zero matches; pipefail then propagates
                                    # that 1 through the always-succeeding
                                    # `wc -l`/`tr`, and `set -e` would abort
                                    # the whole script right here instead of
                                    # reporting a clean 0 count. grep/wc/tr
                                    # are all ScriptFailOpenAuditTest tolerant
                                    # commands, so this is the idiom, not an
                                    # unapproved swallow.
                                    wf_skip_token_count="$(grep -oE -- '--skip([[:space:]]|=)' "$REPO_ROOT/$lr_elem_b" | wc -l | tr -d ' ' || true)"
                                    wf_skip_parsed_count="$(grep -oE -- '--skip[[:space:]]+[A-Za-z0-9_/]+' "$REPO_ROOT/$lr_elem_b" | wc -l | tr -d ' ' || true)"
                                    if [[ "$wf_skip_token_count" -gt "$wf_skip_parsed_count" ]]; then
                                        add_integrity_violation "$id: lane_methods entry '$lm_entry' — ${lr_elem_b} has a --skip argument this gate cannot parse (quoted, --skip=value, or a regex value) — cannot verify '${lm_suite}/${lm_method}' isn't excluded"
                                    else
                                        local wf_skip wf_skip_matched=0
                                        while IFS= read -r wf_skip; do
                                            if [[ -n "$wf_skip" && "${lm_suite}/${lm_method}" == *"$wf_skip"* ]]; then
                                                wf_skip_matched=1
                                                break
                                            fi
                                        done < <(grep -oE -- '--skip[[:space:]]+[A-Za-z0-9_/]+' "$REPO_ROOT/$lr_elem_b" | awk '{print $2}')
                                        if [[ "$wf_skip_matched" -eq 1 ]]; then
                                            add_integrity_violation "$id: lane_methods entry '$lm_entry' — ${lr_elem_b} has a --skip argument that excludes '${lm_suite}/${lm_method}'"
                                        fi
                                    fi
                                    ;;
                            esac
                            ;;
                    esac
                done < <(comma_list_elements "$lane_ref")
            done < <(comma_list_elements "$lane_methods")
        fi

        # Path-shaped lane_ref elements are a promise the file exists, unless
        # the lane is manual/external (where lane_ref is routinely prose).
        if [[ -n "$lane_ref" ]] && ! in_list "$lane" "$PATH_EXEMPT_LANES"; then
            local elem
            while IFS= read -r elem; do
                if is_path_shaped "$elem" && [[ ! -e "$REPO_ROOT/$elem" ]]; then
                    add_integrity_violation "$id: lane_ref element does not exist: $elem"
                fi
            done < <(comma_list_elements "$lane_ref")
        fi
    done < <(tail -n +2 "$MANIFEST" | tr '\t' '\036')
}

count_tabs() {
    # $1: a raw line. Echoes the number of literal tab characters in it.
    printf '%s' "$1" | tr -cd '\t' | wc -c | tr -d ' '
}

# ---- Product completeness audit --------------------------------------------
#
# Every `.library(`/`.executable(` product Package.swift declares must be
# named in some manifest row's `products` column, or listed with a reason in
# scripts/demo-coverage-product-allowlist.txt — otherwise a whole product can
# ship with zero demo-coverage tracking and nobody notices. Skips entirely
# when $REPO_ROOT/Package.swift doesn't exist (every existing sabotage
# fixture has no Package.swift and must stay unaffected by this audit; the
# one fixture that exercises it plants its own).

check_product_completeness() {
    [[ -f "$PACKAGE_SWIFT" ]] || return 0

    local pkg_products
    pkg_products="$(grep -oE '\.(library|executable)\(name: *"[^"]+"' "$PACKAGE_SWIFT" | sed -E 's/.*name: *"([^"]+)"/\1/')"
    [[ -n "$pkg_products" ]] || return 0

    # Fail-closed guard against the extraction regex itself going dormant. The
    # regex above requires `name:` on the SAME line as `.library(`/
    # `.executable(` — a multi-line declaration (name: on its own line) would
    # silently extract zero names for that product and the loop below would
    # never see it, passing clean while a whole product goes untracked. Count
    # non-comment `.library(`/`.executable(` occurrences independently (a
    # naive `//`-to-end-of-line strip — good enough for this file's product
    # list, which never puts a URL literal on a product-declaration line) and
    # compare against the extracted-name count; a mismatch means the
    # extraction regex missed something and the check can't be trusted, so it
    # fails closed with a named error instead of silently under-counting.
    local product_decl_count product_name_count
    product_decl_count="$(sed -E 's|//.*$||' "$PACKAGE_SWIFT" | grep -oE '\.(library|executable)\(' | wc -l | tr -d ' ')"
    product_name_count="$(awk 'END{print NR}' <<< "$pkg_products")"
    if [[ "$product_decl_count" -ne "$product_name_count" ]]; then
        add_integrity_violation "product completeness: found $product_decl_count non-comment .library(/.executable( declaration(s) in Package.swift but only extracted $product_name_count product name(s) — a product declaration likely splits 'name:' onto its own line, which the extraction regex can't see; fix the regex (or the declaration) before trusting this audit"
        return
    fi

    local all_referenced="" id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes
    while IFS=$'\036' read -r id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes; do
        [[ -z "$id" ]] && continue
        local p
        while IFS= read -r p; do
            all_referenced="${all_referenced} ${p}"
        done < <(comma_list_elements "$products")
    done < <(tail -n +2 "$MANIFEST" | tr '\t' '\036')

    local allowlist_names=""
    if [[ -f "$PRODUCT_ALLOWLIST" ]]; then
        local raw allow_prod
        while IFS= read -r raw; do
            allow_prod="${raw%%#*}"
            allow_prod="$(echo "$allow_prod" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "$allow_prod" ]] && continue
            allowlist_names="${allowlist_names} ${allow_prod}"
            if ! printf '%s\n' "$pkg_products" | grep -qx "$allow_prod"; then
                add_integrity_violation "product completeness: allowlist entry '$allow_prod' is not a Package.swift .library/.executable product — stale, remove it from scripts/demo-coverage-product-allowlist.txt"
            fi
            if in_list "$allow_prod" "$all_referenced"; then
                add_integrity_violation "product completeness: allowlist entry '$allow_prod' is now referenced by a manifest row's products column — remove the stale line from scripts/demo-coverage-product-allowlist.txt"
            fi
        done < "$PRODUCT_ALLOWLIST"
    fi

    local prod
    while IFS= read -r prod; do
        [[ -z "$prod" ]] && continue
        if ! in_list "$prod" "$all_referenced" && ! in_list "$prod" "$allowlist_names"; then
            add_integrity_violation "product completeness: '$prod' (Package.swift .library/.executable product) is not referenced by any manifest row's products column and is not in scripts/demo-coverage-product-allowlist.txt"
        fi
    done <<< "$pkg_products"
}

check_manifest_integrity
check_product_completeness

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
    local id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes
    while IFS=$'\036' read -r id title products vehicle_kind vehicle_path doc lane lane_ref lane_methods exec_kind notes; do
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
# "Lexical public-type mentions" — informational only — see the header
# comment for why this is NOT ratcheted. NOTE: --check never calls this — it
# only reads current_state's R1/R2/R3 output, so a type-coverage-helper
# failure can never affect --check or its sabotage fixtures. Only the
# scoreboard (default / --markdown) renders it.

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
    # (unmet) with no corresponding manifest acknowledgement — an
    # UNACCOMPANIED regression. New ids (not in baseline) are allowed.
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

    echo "demo-coverage.sh --check: OK — manifest integrity clean, no unaccompanied ratchet regressions vs $BASELINE"
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
    echo "=== Lexical public-type mentions (informational only — not ratcheted; see script header) ==="
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
    echo "## Lexical public-type mentions (informational only — not ratcheted)"
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
