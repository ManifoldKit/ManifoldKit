#!/usr/bin/env bash
# split-proof.sh — B5 out-of-package compile proof for the companion-package
# split (#1749, v0.48 plan §3 B3 / §5 go/no-go).
#
# Proves the ManifoldMLX / ManifoldLlama family sources compile and pass their
# contract suites OUTSIDE this package, against core's published products —
# the first honest cross-package build, executed BEFORE the C-stream cutover.
# C1 re-runs this script as the go/no-go step when bootstrapping the real
# manifold-mlx / manifold-llama repos.
#
# What it does, per family:
#   1. Copies the family sources into a scratch SwiftPM package under a
#      *renamed* module (ManifoldLlamaSplit / ManifoldMLXSplit). The rename is
#      a proof-only artifact: core still declares targets named ManifoldLlama/
#      ManifoldMLX/FluxSwift/StableDiffusion, and SwiftPM rejects duplicate
#      target names in one package graph. C1's real repos keep the real names
#      because C2 deletes the targets from core.
#   2. Strips the whole-file `#if Llama` / `#if MLX` gates (and any
#      `#if HuggingFace` — always-on per the plan's G3 note). A naive copy
#      compiles to an EMPTY module with green CI — the plan's risk #3.
#   3. Declares core via `.package(path:)` with an explicit
#      `name: "ManifoldKit"` (path-derived identity breaks under non-default
#      checkout paths — CLAUDE.md footgun) and `traits: []` so core's products
#      build trait-less, matching the post-C2 world.
#   4. `swift build` — compile success is the seam holding; failure output is
#      the exact list of seam gaps.
#   5. Copies the family conformance + contract test files, runs `swift test`
#      (no --parallel: BackendContractChecks claims registry is process-global)
#      and enforces NON-VACUITY: at least one test must actually execute.
#
# Not wired into per-PR CI: the MLX leg builds mlx-swift from source (~10+
# minutes). Run locally and at C1.
#
# Usage: scripts/split-proof.sh [--keep-scratch] [--family llama|mlx|all]
set -euo pipefail
# Without inherit_errexit, `set -e` is DISABLED inside $(...) command
# substitution — a failed strip would print its error and the run would
# continue to a dishonest PASSED. Belt: this shopt. Braces: prepare_* are
# called directly (never via $(...)) and communicate through PKG_PATH.
shopt -s inherit_errexit

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP_SCRATCH=0
FAMILY="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-scratch) KEEP_SCRATCH=1; shift ;;
    --family) FAMILY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

SCRATCH="$(mktemp -d -t split-proof)"
echo "==> scratch: $SCRATCH"
cleanup() {
  if [[ "$KEEP_SCRATCH" == "1" ]]; then
    echo "==> keeping scratch at $SCRATCH"
  else
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Gate stripping. The family traits are always-on post-split, so every
# `#if Llama|MLX|HuggingFace` block — whole-file gates AND interior nested
# gates (e.g. MLXBackend.secureWipe's `#if MLX` arbiter path) — keeps its
# if-branch and drops any `#else` branch. Other directives (`#if DEBUG`,
# `#if canImport(...)`, `#if arch(...)`) are preserved untouched. Fails
# LOUDLY on anything it can't prove it handled (negated/compound gates,
# `#elseif`, unbalanced blocks) — silence here is the empty-module trap.
# ---------------------------------------------------------------------------
strip_gates() {
  local dir="$1"
  python3 - "$dir" <<'PY'
import pathlib, sys

GATES = {"#if Llama", "#if MLX", "#if HuggingFace"}
TOKENS = ("MLX", "Llama", "HuggingFace")
root = pathlib.Path(sys.argv[1])
stripped = 0


def degate(lines, path):
    """Resolve family-trait gates as always-true, recursively."""
    out = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s in GATES:
            depth = 0
            else_idx = None
            end = None
            for j in range(i, len(lines)):
                t = lines[j].strip()
                if t.startswith("#if"):
                    depth += 1
                elif t.startswith("#elseif") and depth == 1:
                    sys.exit(f"ERROR: {path}: #elseif under {s} is unsupported — handle manually")
                elif t.startswith("#else") and depth == 1:
                    else_idx = j
                elif t.startswith("#endif"):
                    depth -= 1
                    if depth == 0:
                        end = j
                        break
            if end is None:
                sys.exit(f"ERROR: unbalanced {s} in {path}")
            body_end = else_idx if else_idx is not None else end
            out.extend(degate(lines[i + 1:body_end], path))
            i = end + 1
        else:
            out.append(lines[i])
            i += 1
    return out


for path in sorted(root.rglob("*.swift")):
    lines = path.read_text().split("\n")
    new_lines = degate(lines, path)
    if new_lines != lines:
        path.write_text("\n".join(new_lines))
        stripped += 1

# Loud guard: no family-trait token may survive in ANY #if shape we did not
# resolve (negated `#if !MLX`, compound `#if MLX && Fuzz`, ...).
leftovers = []
for path in sorted(root.rglob("*.swift")):
    for n, line in enumerate(path.read_text().split("\n"), 1):
        s = line.strip()
        if s.startswith("#if") and any(tok in s for tok in TOKENS):
            leftovers.append(f"{path}:{n}: {s}")
if leftovers:
    sys.exit(
        "ERROR: family gates survived the strip (empty-module trap):\n"
        + "\n".join(leftovers)
    )

print(f"    de-gated {stripped} file(s) under {root}")
PY
}

# ---------------------------------------------------------------------------
# Build + test one scratch package; records summary lines in RESULTS.
# ---------------------------------------------------------------------------
RESULTS=()
FAILED=0

build_and_test() {
  local pkg_dir="$1" label="$2"
  local src_count
  src_count=$(find "$pkg_dir/Sources" -name "*.swift" | wc -l | tr -d ' ')

  echo "==> [$label] swift build ($src_count source files)"
  if ! (cd "$pkg_dir" && swift build 2>&1 | tee build.log | tail -5); then
    echo "==> [$label] BUILD FAILED — seam gaps:"
    grep -E "error: " "$pkg_dir/build.log" | sort -u | head -40 || true
    RESULTS+=("$label: BUILD FAILED ($src_count files) — see seam-gap errors above")
    FAILED=1
    return
  fi
  echo "==> [$label] build OK"

  echo "==> [$label] swift test (no --parallel; claims registry is process-global)"
  local test_log="$pkg_dir/test.log"
  local test_status=0
  (cd "$pkg_dir" && swift test 2>&1 | tee test.log | tail -5) || test_status=$?

  # Aggregate XCTest summary: last "Executed N tests" line is the run total.
  local summary
  summary=$(grep -E "Executed [0-9]+ tests?," "$test_log" | tail -1 || true)
  local executed
  executed=$(echo "$summary" | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || echo 0)
  local skipped
  skipped=$(echo "$summary" | grep -oE "[0-9]+ tests? skipped" | grep -oE "[0-9]+" || echo 0)

  if [[ "$test_status" -ne 0 ]]; then
    echo "==> [$label] TESTS FAILED"
    grep -E "error: |failed" "$test_log" | sort -u | head -20 || true
    RESULTS+=("$label: TESTS FAILED ($src_count files compiled; $summary)")
    FAILED=1
    return
  fi

  # NON-VACUITY: an empty-module green run is the failure mode the plan
  # warns about. At least one test must have executed.
  if [[ "$executed" -lt 1 ]]; then
    echo "==> [$label] VACUOUS RUN — zero tests executed"
    RESULTS+=("$label: VACUOUS — 0 tests executed (empty-module trap)")
    FAILED=1
    return
  fi

  RESULTS+=("$label: PASSED — $src_count source files compiled, $executed tests executed ($skipped skipped hardware-gated)")
}

# ---------------------------------------------------------------------------
# manifold-llama-proof
# ---------------------------------------------------------------------------
prepare_llama() {
  local pkg="$SCRATCH/manifold-llama-proof"
  mkdir -p "$pkg/Sources" "$pkg/Tests/ManifoldLlamaSplitTests"

  cp -R "$CORE/Sources/ManifoldLlama" "$pkg/Sources/ManifoldLlamaSplit"
  cp -R "$CORE/Tests/Fixtures" "$pkg/Tests/Fixtures"
  cp "$CORE/Tests/ManifoldBackendsTests/Conformance/LlamaBackendContractTests.swift" \
     "$CORE/Tests/ManifoldBackendsTests/LlamaLocalBackendContractTests.swift" \
     "$pkg/Tests/ManifoldLlamaSplitTests/"

  strip_gates "$pkg"

  # Repoint the copied tests at the renamed proof module. `import
  # ManifoldBackends` is dropped: the umbrella does not exist for companions
  # (verified: neither file references a ManifoldBackends-only symbol).
  for f in "$pkg/Tests/ManifoldLlamaSplitTests/"*.swift; do
    sed -i '' \
      -e 's/import ManifoldLlama$/import ManifoldLlamaSplit/' \
      -e 's|Sources/ManifoldLlama/|Sources/ManifoldLlamaSplit/|g' \
      -e '/^import ManifoldBackends$/d' \
      "$f"
  done

  cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.1
// Generated by scripts/split-proof.sh — scratch proof package, do not ship.
import PackageDescription

let package = Package(
    name: "manifold-llama-proof",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        // name: MUST be explicit — .package(path:) derives identity from the
        // last path component, which breaks under non-default checkout paths.
        // traits: [] builds core's products trait-less (the post-C2 world).
        .package(name: "ManifoldKit", path: "$CORE", traits: []),
        // Pinned EXACT, copied from core's Package.swift: mattt/llama.swift
        // auto-tags a new version per upstream llama.cpp commit; a floating
        // \`from:\` lets CI resolution drift to the newest tag, and the cached
        // SwiftPM clone can land in an "unable to read tree" state for a
        // just-pushed revision. Exact pinning keeps resolution deterministic.
        // Bump intentionally per docs/LLAMA_CONTRACT.md's upgrade procedure.
        .package(url: "https://github.com/mattt/llama.swift", exact: "2.9553.0"),
    ],
    targets: [
        .target(
            name: "ManifoldLlamaSplit",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldHardware", package: "ManifoldKit"),
                .product(name: "ManifoldContract", package: "ManifoldKit"),
                .product(name: "LlamaSwift", package: "llama.swift"),
            ]
        ),
        .testTarget(
            name: "ManifoldLlamaSplitTests",
            dependencies: [
                "ManifoldLlamaSplit",
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldTestSupport", package: "ManifoldKit"),
                .product(name: "ManifoldBackendTestKit", package: "ManifoldKit"),
            ]
        ),
    ]
)
EOF
  PKG_PATH="$pkg"
}

# ---------------------------------------------------------------------------
# manifold-mlx-proof (includes vendored FluxSwift + StableDiffusion — both
# imported by ManifoldMLX sources, so they travel with the family)
# ---------------------------------------------------------------------------
prepare_mlx() {
  local pkg="$SCRATCH/manifold-mlx-proof"
  mkdir -p "$pkg/Sources" "$pkg/Tests/ManifoldMLXSplitTests"

  cp -R "$CORE/Sources/ManifoldMLX" "$pkg/Sources/ManifoldMLXSplit"
  cp -R "$CORE/Sources/FluxSwift" "$pkg/Sources/FluxSwiftSplit"
  cp -R "$CORE/Sources/StableDiffusion" "$pkg/Sources/StableDiffusionSplit"
  rm -rf "$pkg/Sources/ManifoldMLXSplit/ManifoldMLX.docc"
  cp -R "$CORE/Tests/Fixtures" "$pkg/Tests/Fixtures"
  cp "$CORE/Tests/ManifoldBackendsTests/Conformance/MLXBackendConformanceTests.swift" \
     "$CORE/Tests/ManifoldBackendsTests/MLXLocalBackendContractTests.swift" \
     "$pkg/Tests/ManifoldMLXSplitTests/"

  strip_gates "$pkg"

  # Repoint vendored-module imports at the renamed proof targets.
  find "$pkg/Sources/ManifoldMLXSplit" -name "*.swift" -exec sed -i '' \
    -e 's/^import FluxSwift$/import FluxSwiftSplit/' \
    -e 's/^import StableDiffusion$/import StableDiffusionSplit/' \
    {} +

  for f in "$pkg/Tests/ManifoldMLXSplitTests/"*.swift; do
    sed -i '' \
      -e 's/import ManifoldMLX$/import ManifoldMLXSplit/' \
      -e 's|Sources/ManifoldMLX/|Sources/ManifoldMLXSplit/|g' \
      -e '/^import ManifoldBackends$/d' \
      "$f"
  done

  cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.1
// Generated by scripts/split-proof.sh — scratch proof package, do not ship.
import PackageDescription

let package = Package(
    name: "manifold-mlx-proof",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        // name: MUST be explicit — .package(path:) derives identity from the
        // last path component, which breaks under non-default checkout paths.
        // traits: [] builds core's products trait-less (the post-C2 world).
        .package(name: "ManifoldKit", path: "$CORE", traits: []),
        // Pins copied from core's Package.swift.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        // 3.31.3 ships the decoupled MLXHuggingFace target and adds the
        // \`gemma4\` model_type to LLMTypeRegistry.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        // Explicit dep required: mlx-swift-lm no longer pulls
        // swift-transformers transitively.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
        // swift-log: pulled in by vendored FluxSwift source.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Vendored FluxSwift (mzbac/flux.swift, MIT) — vendored because
        // upstream pins swift-transformers 0.1.x; core requires 1.2.x.
        .target(
            name: "FluxSwiftSplit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Vendored StableDiffusion (from mlx-swift-examples, MIT).
        .target(
            name: "StableDiffusionSplit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            exclude: ["LICENSE"]
        ),
        .target(
            name: "ManifoldMLXSplit",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                "StableDiffusionSplit",
                "FluxSwiftSplit",
            ]
        ),
        .testTarget(
            name: "ManifoldMLXSplitTests",
            dependencies: [
                "ManifoldMLXSplit",
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldTestSupport", package: "ManifoldKit"),
                .product(name: "ManifoldBackendTestKit", package: "ManifoldKit"),
            ]
        ),
    ]
)
EOF
  PKG_PATH="$pkg"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
PKG_PATH=""

if [[ "$FAMILY" == "llama" || "$FAMILY" == "all" ]]; then
  echo "==> preparing manifold-llama-proof"
  prepare_llama
  build_and_test "$PKG_PATH" "manifold-llama"
fi

if [[ "$FAMILY" == "mlx" || "$FAMILY" == "all" ]]; then
  echo "==> preparing manifold-mlx-proof"
  prepare_mlx
  build_and_test "$PKG_PATH" "manifold-mlx"
fi

echo ""
echo "============================================================"
if [[ "$FAILED" == "0" ]]; then
  echo "PROOF: PASSED"
else
  echo "PROOF: FAILED"
fi
for r in "${RESULTS[@]}"; do
  echo "  - $r"
done
echo "============================================================"
exit "$FAILED"
