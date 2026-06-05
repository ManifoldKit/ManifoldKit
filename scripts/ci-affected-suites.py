#!/usr/bin/env python3
"""scripts/ci-affected-suites.py — Tier 0 selective-testing resolver (issue #1588).

Given the set of files changed in a PR, compute which of the per-PR `test`-job
suites actually need to run, using the SwiftPM target dependency graph.

`swift test --filter X` only prunes *execution*, not *compile* (the whole test
bundle still builds — see #1588 / #1590), so this saves the execution half only.
Realistic win: a narrow PR ~16m -> ~12-13m. Compile pruning is Tier 2 (#1590).

Design (matches #1588):
  1. Read the maximal target graph from `swift package --enable-all-traits
     describe --type json`. The `--enable-all-traits` is LOAD-BEARING: plain
     `describe` reflects only default-ON traits, so trait-gated test targets
     (ManifoldVoiceTests, ManifoldAppIntentsTests, ...) report incomplete deps
     and we would UNDER-include suites -> false green. We always want the
     conservative (maximal) closure.
  2. Map each changed file to a target via longest-prefix match on the target's
     real `.path` (NOT `Sources/<name>` — `ManifoldBackends` lives in
     `Sources/ManifoldBackendsUmbrella/`).
  3. A changed source target selects every CI suite whose transitive dependency
     closure includes it (reverse closure). A changed CI test target selects
     itself.

Safety net (fail OPEN — when in doubt, run everything):
  - Force-full when any changed path matches FORCE_FULL_PATTERNS (manifests,
    .github/**, the test harness, this resolver itself, or a hub module).
  - Force-full when a path under Sources/ or Tests/ maps to no known target.
  - Force-full when describe fails or the graph can't be built.
  - Force-full when the computed set is empty but real source/test code changed.

Outputs (GitHub Actions `$GITHUB_OUTPUT` if set, else stdout):
  full=true|false              # true => run the entire hardcoded suite list
  step1_filters=<args>         # e.g. "--filter ManifoldCoreTests --filter ..."
  run_backends=true|false      # ManifoldBackendsTests (serial step)
  run_swift_testing=true|false # ManifoldInferenceSwiftTestingTests (isolated step)
  suites=<comma list>          # human-readable selected set
  reason=<text>                # why full was forced (when full=true)

A human-readable log always goes to stderr so it shows up in the CI step.

Usage:
  ci-affected-suites.py --changed-files PATH [--describe-json PATH]
  printf 'Sources/ManifoldMLX/Foo.swift\n' | ci-affected-suites.py --changed-files -
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

# CI-runnable suites in the per-PR `test` job, partitioned by how the workflow
# runs them. Keep in sync with .github/workflows/ci.yml `test` job.
STEP1_SUITES = [
    "ManifoldCoreTests",
    "ManifoldRuntimeTests",
    "ManifoldPersistenceSwiftDataTests",
    "ManifoldUITests",
    "ManifoldUIModelManagementTests",
    "ManifoldMCPTests",
    "ManifoldTestSupportTests",
    "ManifoldAppIntentsTests",
    "ManifoldInferenceTests",
    "ManifoldNetworkingTests",
    "ManifoldTurnLoopCharacterizationTests",
]
SERIAL_SUITE = "ManifoldBackendsTests"            # claims-registry race -> serial (#1601)
SWIFT_TESTING_SUITE = "ManifoldInferenceSwiftTestingTests"  # isolated process (#681)

CI_RUNNABLE = STEP1_SUITES + [SERIAL_SUITE, SWIFT_TESTING_SUITE]

# Any changed path matching these forces a full run. The hub modules are listed
# explicitly even though their reverse-closure fanout is already ~13/13: it makes
# the intent legible and covers the 12/13 near-hubs (TestSupport, Runtime,
# Persistence) whose one missing suite we never want to skip.
FORCE_FULL_PATTERNS = [
    re.compile(r"^Package\.swift$"),
    re.compile(r"^Package\.resolved$"),
    re.compile(r"^\.github/"),
    re.compile(r"^scripts/test\.sh$"),
    re.compile(r"^scripts/ci-test-with-watchdog\.sh$"),
    re.compile(r"^scripts/ci-affected-suites\.py$"),  # the resolver gates itself
    re.compile(r"^Sources/ManifoldInference/"),
    re.compile(r"^Sources/ManifoldRuntime/"),
    re.compile(r"^Sources/ManifoldPersistenceSwiftData/"),
    re.compile(r"^Sources/ManifoldTestSupport/"),
    re.compile(r"^Sources/ManifoldNetworking/"),
]

# Roots whose changes must map to a known target or we fail open.
CODE_ROOTS = ("Sources/", "Tests/")


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def load_describe(describe_json: str | None) -> dict:
    if describe_json:
        with open(describe_json) as fh:
            return json.load(fh)
    out = subprocess.run(
        ["swift", "package", "--enable-all-traits", "describe", "--type", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(out.stdout)


def build_graph(pkg: dict):
    targets = {t["name"]: t for t in pkg["targets"]}
    deps = {n: set(t.get("target_dependencies") or []) for n, t in targets.items()}
    # (path, name) sorted longest-path-first for prefix matching.
    paths = sorted(
        ((t["path"].rstrip("/"), t["name"]) for t in pkg["targets"]),
        key=lambda pn: len(pn[0]),
        reverse=True,
    )
    return targets, deps, paths


def closure(name: str, deps: dict, seen: set | None = None) -> set:
    if seen is None:
        seen = set()
    for d in deps.get(name, ()):
        if d not in seen:
            seen.add(d)
            closure(d, deps, seen)
    return seen


def reverse_map(deps: dict) -> dict:
    """source target -> set of CI_RUNNABLE suites whose closure includes it."""
    rev: dict[str, set] = {}
    for suite in CI_RUNNABLE:
        for member in closure(suite, deps) | {suite}:
            rev.setdefault(member, set()).add(suite)
    return rev


def path_to_target(path: str, paths) -> str | None:
    for tpath, name in paths:
        if path == tpath or path.startswith(tpath + "/"):
            return name
    return None


def emit(outputs: dict) -> None:
    gh = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{k}={v}" for k, v in outputs.items()]
    if gh:
        with open(gh, "a") as fh:
            fh.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))
    # Stable, greppable telemetry marker for the dry-run aggregator
    # (scripts/ci-tier0-dryrun-report.sh scans CI logs for this prefix). One
    # line per resolver run; do not reformat without updating the aggregator.
    suites = outputs.get("suites", "")
    selected = 0 if not suites else len(suites.split(","))
    log(f"TIER0_DRYRUN full={outputs.get('full')} "
        f"selected={selected} total={len(CI_RUNNABLE)}")


def full_run(reason: str) -> dict:
    log(f"FORCE-FULL: {reason}")
    log(f"Running all {len(CI_RUNNABLE)} CI suites.")
    return {
        "full": "true",
        "step1_filters": " ".join(f"--filter {s}" for s in STEP1_SUITES),
        "run_backends": "true",
        "run_swift_testing": "true",
        "suites": ",".join(CI_RUNNABLE),
        "reason": reason,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed-files",
                    help="file with newline-separated changed paths, or '-' for stdin")
    ap.add_argument("--describe-json", default=None,
                    help="precomputed `swift package describe` JSON (testing); "
                         "otherwise invokes swift")
    ap.add_argument("--force-full", action="store_true",
                    help="unconditionally select every CI suite (push to main / "
                         "nightly / any event where selective testing must not apply)")
    args = ap.parse_args()

    if args.force_full:
        emit(full_run("--force-full requested (non-PR event)"))
        return 0

    if not args.changed_files:
        ap.error("--changed-files is required unless --force-full is given")

    if args.changed_files == "-":
        raw = sys.stdin.read()
    else:
        with open(args.changed_files) as fh:
            raw = fh.read()
    changed = [ln.strip() for ln in raw.splitlines() if ln.strip()]

    if not changed:
        # Empty diff should not happen on a real PR; fail open.
        emit(full_run("empty changed-files list"))
        return 0

    log(f"Changed files: {len(changed)}")

    for path in changed:
        for pat in FORCE_FULL_PATTERNS:
            if pat.search(path):
                emit(full_run(f"changed path '{path}' matches force-full rule"))
                return 0

    try:
        pkg = load_describe(args.describe_json)
        targets, deps, paths = build_graph(pkg)
    except Exception as exc:  # noqa: BLE001 — any describe failure fails open
        emit(full_run(f"could not build package graph: {exc}"))
        return 0

    rev = reverse_map(deps)
    selected: set[str] = set()

    for path in changed:
        if path.startswith(CODE_ROOTS):
            tgt = path_to_target(path, paths)
            if tgt is None:
                emit(full_run(f"changed code path '{path}' maps to no known target"))
                return 0
            if targets[tgt].get("type") == "test":
                if tgt in CI_RUNNABLE:
                    selected.add(tgt)
                # A non-CI test target (E2E, Server, MLXIntegration, ...) is
                # handled by its own gated job / nightly — it adds nothing here.
            else:
                selected |= rev.get(tgt, set())
        # Non-code paths (docs, etc.) that slipped the workflow path filter
        # contribute nothing; if they are the ONLY changes we fail open below.

    if not selected:
        emit(full_run("no CI suite mapped from the changed set"))
        return 0

    selected_step1 = [s for s in STEP1_SUITES if s in selected]
    log(f"Selected {len(selected)}/{len(CI_RUNNABLE)} suites: {sorted(selected)}")

    emit({
        "full": "false",
        "step1_filters": " ".join(f"--filter {s}" for s in selected_step1),
        "run_backends": "true" if SERIAL_SUITE in selected else "false",
        "run_swift_testing": "true" if SWIFT_TESTING_SUITE in selected else "false",
        "suites": ",".join(sorted(selected)),
        "reason": "",
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
