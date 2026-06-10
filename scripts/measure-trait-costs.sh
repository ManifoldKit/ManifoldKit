#!/usr/bin/env bash
# measure-trait-costs.sh — Measure the per-trait binary, build-time, and
# dependency weight of each SwiftPM trait in ManifoldKit and render the results
# to docs/trait-costs.json and docs/TRAIT-COSTS.md.
#
# Background:
#   SwiftPM traits (SE-0450, Swift 6.1) gate COMPILATION and LINKING, not
#   dependency RESOLUTION. Every package declared in Package.swift is cloned
#   into .build/checkouts regardless of the active trait set. The fetch-pruning
#   "future direction" mentioned in SE-0450 is not yet implemented (as of
#   Swift 6.1 / Xcode 26). See docs/TRAIT-COSTS.md for the full story.
#
# Usage:
#   scripts/measure-trait-costs.sh            # full measurement
#   scripts/measure-trait-costs.sh --quick    # skip build-time measurements
#   scripts/measure-trait-costs.sh --render-only  # re-render docs from existing JSON
#
# Output:
#   docs/trait-costs.json   — machine-readable measurements (each run appends/replaces)
#   docs/TRAIT-COSTS.md     — rendered markdown table
#
# Prerequisites: macOS + Apple Silicon, Xcode / Swift toolchain installed.
# Do NOT wire the full measurement run into per-PR CI — each release build is
# expensive and the run-count discipline (CLAUDE.md) applies. Run locally before
# a release or whenever trait weights change materially.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$REPO_ROOT/docs"
JSON_OUT="$DOCS/trait-costs.json"
MD_OUT="$DOCS/TRAIT-COSTS.md"

# ─── flags ───────────────────────────────────────────────────────────────────
QUICK=0
RENDER_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --quick)       QUICK=1 ;;
        --render-only) RENDER_ONLY=1 ;;
    esac
done

# ─── helpers ─────────────────────────────────────────────────────────────────

log() { echo "==> $*" >&2; }

# Return stripped binary size in bytes for a given trait flag string.
# Builds release, strips, then measures the produced library objects.
# Wipes only per-build state (.build/debug .build/release .build/build.db)
# but preserves .build/checkouts and .build/artifacts so the xcframework
# does not need to be re-downloaded on every iteration.
measure_binary_kb() {
    local trait_flags="$1"   # e.g. "--disable-default-traits" or "--traits MLX"
    local label="$2"

    log "Building [$label] release..."
    # shellcheck disable=SC2086
    if ! swift build -c release $trait_flags --package-path "$REPO_ROOT" > /tmp/trait-build-out.log 2>&1; then
        tail -10 /tmp/trait-build-out.log >&2 || true
        echo "BUILD_FAILED"
        return
    fi
    tail -3 /tmp/trait-build-out.log >&2 || true

    # Locate arm64 release build dir. SwiftPM names it after the arch-triple.
    local build_root
    build_root=$(ls -d "$REPO_ROOT/.build/"*-apple-macosx/release/ 2>/dev/null | head -1)
    if [[ -z "$build_root" ]]; then
        echo "NOT_FOUND"
        return
    fi

    # Sum all .o files in the release build root (stripped in-place with -x).
    # `strip -x` removes debug symbols and local symbols, leaving only globals —
    # this matches what a linker-dead-stripped App Store binary looks like.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    local total=0
    while IFS= read -r obj; do
        local stripped="$tmp_dir/$(basename "$obj")"
        cp "$obj" "$stripped"
        strip -x "$stripped" 2>/dev/null || true
        local sz
        sz=$(stat -f%z "$stripped" 2>/dev/null || echo 0)
        total=$((total + sz))
    done < <(find "$build_root" -maxdepth 3 -name "ManifoldBackends.build" -prune -o \
        -name "*.o" -not -path "*Tests*" -not -path "*TestSupport*" -print 2>/dev/null)

    echo $((total / 1024))
}

# Return wall-clock seconds for a release build of a given trait set.
measure_build_seconds() {
    local trait_flags="$1"

    # Wipe built objects but keep checkouts/artifacts.
    rm -rf "$REPO_ROOT/.build/debug" "$REPO_ROOT/.build/release" "$REPO_ROOT/.build/build.db" 2>/dev/null || true

    local start_time
    start_time=$(date +%s)
    # shellcheck disable=SC2086
    if ! swift build -c release $trait_flags --package-path "$REPO_ROOT" > /tmp/trait-build-time.log 2>&1; then
        echo "BUILD_FAILED"
        return
    fi
    local end_time
    end_time=$(date +%s)
    echo $((end_time - start_time))
}

# Parse .build/checkouts sizes into JSON. Returns bytes for a given checkout dir name.
checkout_size_mb() {
    local dir="$1"
    local path="$REPO_ROOT/.build/checkouts/$dir"
    if [[ -d "$path" ]]; then
        du -sm "$path" 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

artifact_size_mb() {
    local dir="$1"
    local path="$REPO_ROOT/.build/artifacts/$dir"
    if [[ -d "$path" ]]; then
        du -sm "$path" 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

# ─── dependency attribution mapping ──────────────────────────────────────────
# Maps each trait to the external packages it exclusively pulls into the build
# graph. This is a curated mapping: entries are checked against Package.swift by
# TraitCostsDriftTest. The rule is "what packages would NOT be compiled without
# this trait" — shared deps (Foundation, swift-log) are not attributed to any
# single trait.
#
# Format: TRAIT → space-separated checkout directory names.
# The drift test in Tests/ validates that every attributed checkout still exists
# in .build/checkouts after resolve, and that every heavy checkout (>5 MB) is
# attributed somewhere.

declare -A TRAIT_DEPS
TRAIT_DEPS["MLX"]="mlx-swift mlx-swift-lm"
TRAIT_DEPS["Llama"]="llama.swift"          # xcframework in artifacts/llama.swift
TRAIT_DEPS["HuggingFace"]="swift-huggingface"
TRAIT_DEPS["CloudSaaS"]=""                 # ManifoldCloudCore always compiled; no unique checkout
TRAIT_DEPS["Ollama"]=""                    # same ManifoldCloudCore path, no unique checkout
TRAIT_DEPS["MCP"]=""                       # pure ManifoldKit sources, no external package
TRAIT_DEPS["MCPBuiltinCatalog"]=""         # compile flag only
TRAIT_DEPS["Voice"]=""                     # pure AVFoundation/Speech, no external package
TRAIT_DEPS["Tools"]=""                     # ManifoldTools = pure ManifoldKit sources
TRAIT_DEPS["AppIntents"]=""               # pure AppIntents framework, no external package
TRAIT_DEPS["Server"]="EventSource swift-nio swift-crypto swift-collections swift-atomics swift-system"
TRAIT_DEPS["Macros"]="swift-syntax"
TRAIT_DEPS["Skills"]=""                   # pure ManifoldKit sources
TRAIT_DEPS["Fuzz"]=""                     # fuzz-chat executable only
TRAIT_DEPS["AnyLanguageModel"]=""         # AnyLanguageModel package always resolved
TRAIT_DEPS["FoundationOnly"]=""           # override that removes deps; measured as baseline

# Modules added per trait (informational, shown in the table)
declare -A TRAIT_MODULES
TRAIT_MODULES["MLX"]="ManifoldMLX + StableDiffusion + FluxSwift"
TRAIT_MODULES["Llama"]="ManifoldLlama"
TRAIT_MODULES["HuggingFace"]="ManifoldHuggingFace"
TRAIT_MODULES["CloudSaaS"]="ManifoldCloud (SaaS bodies)"
TRAIT_MODULES["Ollama"]="ManifoldCloud (Ollama bodies)"
TRAIT_MODULES["MCP"]="ManifoldMCP + ManifoldMCPHost"
TRAIT_MODULES["MCPBuiltinCatalog"]="ManifoldMCP built-in catalog"
TRAIT_MODULES["Voice"]="ManifoldVoice"
TRAIT_MODULES["Tools"]="ManifoldTools + manifold-tools CLI"
TRAIT_MODULES["AppIntents"]="ManifoldAppIntents"
TRAIT_MODULES["Server"]="ManifoldServer + Hummingbird"
TRAIT_MODULES["Macros"]="ManifoldMacrosPlugin + @ToolSchema"
TRAIT_MODULES["Skills"]="ManifoldSkills"
TRAIT_MODULES["Fuzz"]="fuzz-chat executable (real backends)"
TRAIT_MODULES["AnyLanguageModel"]="AnyLanguageModel bridge"
TRAIT_MODULES["FoundationOnly"]="FoundationBackend only (removes MLX+Llama+HuggingFace defaults)"

# Trait flags used for each measurement (added on top of baseline).
# Baseline = --disable-default-traits (no MLX, no Llama, no HuggingFace).
# Exception: FoundationOnly is a consumer-override trait, not additive.
declare -A TRAIT_FLAGS
TRAIT_FLAGS["MLX"]="--traits MLX"
TRAIT_FLAGS["Llama"]="--traits Llama"
TRAIT_FLAGS["HuggingFace"]="--traits HuggingFace"
TRAIT_FLAGS["CloudSaaS"]="--disable-default-traits --traits CloudSaaS"
TRAIT_FLAGS["Ollama"]="--disable-default-traits --traits Ollama"
TRAIT_FLAGS["MCP"]="--disable-default-traits --traits MCP"
TRAIT_FLAGS["MCPBuiltinCatalog"]="--disable-default-traits --traits MCP,MCPBuiltinCatalog"
TRAIT_FLAGS["Voice"]="--disable-default-traits --traits Voice"
TRAIT_FLAGS["Tools"]="--disable-default-traits --traits Tools"
TRAIT_FLAGS["AppIntents"]="--disable-default-traits --traits AppIntents"
TRAIT_FLAGS["Server"]="--disable-default-traits --traits Server"
TRAIT_FLAGS["Macros"]="--disable-default-traits --traits Macros"
TRAIT_FLAGS["Skills"]="--disable-default-traits --traits Skills"
TRAIT_FLAGS["Fuzz"]="--disable-default-traits --traits Fuzz,MLX,Llama"
TRAIT_FLAGS["AnyLanguageModel"]="--disable-default-traits --traits AnyLanguageModel"
TRAIT_FLAGS["FoundationOnly"]="--traits FoundationOnly"

# Ordered list of traits to measure
TRAITS_TO_MEASURE=(
    FoundationOnly
    MLX
    Llama
    HuggingFace
    CloudSaaS
    Ollama
    MCP
    MCPBuiltinCatalog
    Server
    Macros
    Skills
    Voice
    Tools
    AppIntents
    AnyLanguageModel
    Fuzz
)

# ─── main ─────────────────────────────────────────────────────────────────────

if [[ "$RENDER_ONLY" -eq 1 ]]; then
    if [[ ! -f "$JSON_OUT" ]]; then
        echo "error: $JSON_OUT not found — run without --render-only first" >&2
        exit 1
    fi
    log "Render-only mode: reading $JSON_OUT"
else
    log "Running swift package resolve..."
    swift package resolve --package-path "$REPO_ROOT" 2>&1 | tail -3

    # Collect checkout sizes (fetched regardless of trait set)
    log "Measuring checkout and artifact sizes..."
    CHECKOUT_TOTAL=$(du -sm "$REPO_ROOT/.build/checkouts" 2>/dev/null | awk '{print $1}')
    ARTIFACT_TOTAL=$(du -sm "$REPO_ROOT/.build/artifacts" 2>/dev/null | awk '{print $1}')

    MLX_SWIFT_MB=$(checkout_size_mb mlx-swift)
    MLX_SWIFT_LM_MB=$(checkout_size_mb mlx-swift-lm)
    LLAMA_SWIFT_MB=$(checkout_size_mb llama.swift)
    LLAMA_ARTIFACT_MB=$(artifact_size_mb llama.swift)
    HF_MB=$(checkout_size_mb swift-huggingface)
    SYNTAX_MB=$(checkout_size_mb swift-syntax)
    NIO_MB=$(checkout_size_mb swift-nio)
    HB_MB=$(checkout_size_mb hummingbird 2>/dev/null || echo 0)  # may not exist standalone

    MEASURED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TOOLCHAIN=$(swift --version 2>&1 | head -1)
    MACHINE="Apple Silicon ($(uname -m))"
    METHOD_VERSION="1"

    log "Checkout total: ${CHECKOUT_TOTAL} MB"
    log "Artifact total: ${ARTIFACT_TOTAL} MB (incl. llama.cpp xcframework)"

    # ── baseline measurement ──────────────────────────────────────────────────
    # Baseline = --disable-default-traits.
    # We measure each trait ADDED TO THIS BASELINE (not combinations).
    # Deltas don't sum — a consumer adding both MLX and Llama pays less than
    # the two individual deltas, because shared infrastructure (ManifoldInference,
    # ManifoldModelCatalog, etc.) is counted once.

    BASELINE_FLAGS="--disable-default-traits"

    if [[ "$QUICK" -eq 0 ]]; then
        log "Measuring baseline binary size (--disable-default-traits)..."
        BASELINE_KB=$(measure_binary_kb "$BASELINE_FLAGS" "baseline")
        log "Measuring baseline build time (--disable-default-traits)..."
        BASELINE_S=$(measure_build_seconds "$BASELINE_FLAGS")
        log "Baseline: ${BASELINE_KB} KB, ${BASELINE_S}s"
    else
        log "Quick mode: skipping build-time measurements"
        BASELINE_KB="N/A"
        BASELINE_S="N/A"
    fi

    # ── per-trait measurements ────────────────────────────────────────────────
    # Build JSON entries for each trait
    declare -A TRAIT_BINARY_KB
    declare -A TRAIT_BINARY_DELTA_KB
    declare -A TRAIT_BUILD_S
    declare -A TRAIT_BUILD_DELTA_S
    declare -A TRAIT_CHECKOUT_MB
    declare -A TRAIT_ARTIFACT_MB

    for trait in "${TRAITS_TO_MEASURE[@]}"; do
        flags="${TRAIT_FLAGS[$trait]}"
        deps="${TRAIT_DEPS[$trait]:-}"

        # Checkout MB: sum attributed checkouts
        checkout_mb=0
        artifact_mb=0
        for dep in $deps; do
            if [[ "$dep" == "llama.swift" ]]; then
                # llama.swift lands in artifacts, not checkouts
                mb=$(artifact_size_mb llama.swift)
                artifact_mb=$((artifact_mb + mb))
            else
                mb=$(checkout_size_mb "$dep")
                checkout_mb=$((checkout_mb + mb))
            fi
        done
        TRAIT_CHECKOUT_MB[$trait]=$checkout_mb
        TRAIT_ARTIFACT_MB[$trait]=$artifact_mb

        if [[ "$QUICK" -eq 0 ]]; then
            log "Measuring binary size for trait [$trait]..."
            binary_kb=$(measure_binary_kb "$flags" "$trait")
            TRAIT_BINARY_KB[$trait]=$binary_kb

            if [[ "$binary_kb" == "BUILD_FAILED" || "$binary_kb" == "NOT_FOUND" ]]; then
                TRAIT_BINARY_DELTA_KB[$trait]="N/A"
            elif [[ "$BASELINE_KB" == "N/A" ]]; then
                TRAIT_BINARY_DELTA_KB[$trait]="N/A"
            else
                delta=$((binary_kb - BASELINE_KB))
                TRAIT_BINARY_DELTA_KB[$trait]=$delta
            fi

            log "Measuring build time for trait [$trait]..."
            build_s=$(measure_build_seconds "$flags")
            TRAIT_BUILD_S[$trait]=$build_s

            if [[ "$build_s" == "BUILD_FAILED" ]]; then
                TRAIT_BUILD_DELTA_S[$trait]="N/A"
            elif [[ "$BASELINE_S" == "N/A" ]]; then
                TRAIT_BUILD_DELTA_S[$trait]="N/A"
            else
                delta_s=$((build_s - BASELINE_S))
                TRAIT_BUILD_DELTA_S[$trait]=$delta_s
            fi
        else
            TRAIT_BINARY_KB[$trait]="N/A"
            TRAIT_BINARY_DELTA_KB[$trait]="N/A"
            TRAIT_BUILD_S[$trait]="N/A"
            TRAIT_BUILD_DELTA_S[$trait]="N/A"
        fi
    done

    # ── emit JSON ─────────────────────────────────────────────────────────────
    mkdir -p "$DOCS"

    # Build JSON array
    JSON_ENTRIES=""
    for trait in "${TRAITS_TO_MEASURE[@]}"; do
        deps_str="${TRAIT_DEPS[$trait]:-}"
        # Convert space-separated deps to JSON array
        deps_json="["
        first=1
        for d in $deps_str; do
            [[ $first -eq 0 ]] && deps_json+=","
            deps_json+="\"$d\""
            first=0
        done
        deps_json+="]"

        modules="${TRAIT_MODULES[$trait]:-}"
        binary_delta="${TRAIT_BINARY_DELTA_KB[$trait]:-N/A}"
        build_delta="${TRAIT_BUILD_DELTA_S[$trait]:-N/A}"
        checkout_mb="${TRAIT_CHECKOUT_MB[$trait]:-0}"
        artifact_mb="${TRAIT_ARTIFACT_MB[$trait]:-0}"

        # JSON-escape strings
        modules_escaped="${modules//\"/\\\"}"

        [[ -n "$JSON_ENTRIES" ]] && JSON_ENTRIES+=","
        JSON_ENTRIES+="{
  \"trait\": \"$trait\",
  \"modules_added\": \"$modules_escaped\",
  \"transitive_deps\": $deps_json,
  \"checkout_attributed_mb\": $checkout_mb,
  \"artifact_mb\": $artifact_mb,
  \"binary_delta_kb\": \"$binary_delta\",
  \"cold_build_delta_s\": \"$build_delta\",
  \"measured_at\": \"$MEASURED_AT\",
  \"toolchain\": \"$TOOLCHAIN\",
  \"machine\": \"$MACHINE\",
  \"method_version\": \"$METHOD_VERSION\"
}"
    done

    # Write combined JSON
    {
        printf '{\n'
        printf '  "schema_version": "1",\n'
        printf '  "method_version": "%s",\n' "$METHOD_VERSION"
        printf '  "note": "Deltas are each trait added to the disable-default-traits baseline. They do NOT sum — adding multiple traits pays shared infrastructure once.",\n'
        printf '  "checkout_total_mb": %s,\n' "$CHECKOUT_TOTAL"
        printf '  "artifact_total_mb": %s,\n' "$ARTIFACT_TOTAL"
        printf '  "generated_at": "%s",\n' "$MEASURED_AT"
        printf '  "toolchain": "%s",\n' "$TOOLCHAIN"
        printf '  "machine": "%s",\n' "$MACHINE"
        printf '  "quick_mode": %s,\n' "$([[ $QUICK -eq 1 ]] && echo 'true' || echo 'false')"
        printf '  "traits": [%s\n  ]\n' "$JSON_ENTRIES"
        printf '}\n'
    } > "$JSON_OUT"

    log "Wrote $JSON_OUT"
fi

# ─── render markdown ──────────────────────────────────────────────────────────
render_markdown() {
    local json="$1"
    local out="$2"

    # Use a Swift one-liner to parse the JSON and render the table.
    # This mirrors the render-feature-matrix.sh pattern.
    local RENDER_SWIFT
    RENDER_SWIFT=$(cat <<'SWIFT'
import Foundation

let path = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let data = FileManager.default.contents(atPath: path),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let traits = root["traits"] as? [[String: Any]] else {
    fputs("error: cannot read or parse \(path)\n", stderr)
    exit(1)
}

let checkoutTotal = root["checkout_total_mb"] as? Int ?? 0
let artifactTotal = root["artifact_total_mb"] as? Int ?? 0
let generatedAt   = root["generated_at"] as? String ?? "unknown"
let toolchain     = root["toolchain"] as? String ?? "unknown"
let machine       = root["machine"] as? String ?? "unknown"
let quickMode     = root["quick_mode"] as? Bool ?? false

// ── generated region ──────────────────────────────────────────────────────

var lines: [String] = []

lines.append("<!-- BEGIN GENERATED — do not edit by hand; run scripts/measure-trait-costs.sh to regenerate -->")
lines.append("")
lines.append("## Per-trait cost table")
lines.append("")
lines.append("> Generated \(generatedAt) on \(machine).")
lines.append("> Toolchain: `\(toolchain)`.")
if quickMode {
    lines.append("> **Quick mode** — build-time and binary-size measurements skipped.")
}
lines.append(">")
lines.append("> **Approx. note:** Binary-delta and build-time columns are approximations measured on one machine")
lines.append("> at one point in time. Rerun `scripts/measure-trait-costs.sh` after any heavy dependency bump.")
lines.append(">")
lines.append("> **Resolution note:** Checkout weights are fetched *regardless of trait set* — SwiftPM traits gate")
lines.append("> compilation and linking, not dependency resolution. See the \"Why the clone is heavy\" section below.")
lines.append("")

// Table header
lines.append("| Trait | Adds modules | Transitive deps | Checkout weight MB ¹ | Artifact MB ² | Binary impact approx. KB ³ | Cold-build added approx. s ⁴ |")
lines.append("|-------|--------------|-----------------|----------------------|---------------|----------------------------|-----------------------------|")

for trait in traits {
    let name        = trait["trait"] as? String ?? "?"
    let modules     = trait["modules_added"] as? String ?? ""
    let deps        = (trait["transitive_deps"] as? [String] ?? [])
    let checkoutMb  = trait["checkout_attributed_mb"] as? Int ?? 0
    let artifactMb  = trait["artifact_mb"] as? Int ?? 0
    let binaryDelta = trait["binary_delta_kb"] as? String ?? "N/A"
    let buildDelta  = trait["cold_build_delta_s"] as? String ?? "N/A"

    let depsStr = deps.isEmpty ? "_(none beyond baseline)_" : deps.map { "`\($0)`" }.joined(separator: ", ")
    let checkoutStr = checkoutMb == 0 ? "—" : "~\(checkoutMb)"
    let artifactStr = artifactMb == 0 ? "—" : "~\(artifactMb)"
    let binaryStr   = binaryDelta == "N/A" ? "—" : binaryDelta.hasPrefix("-") ? binaryDelta : "+\(binaryDelta)"
    let buildStr    = buildDelta == "N/A" ? "—" : buildDelta.hasPrefix("-") ? buildDelta : "+\(buildDelta)"

    lines.append("| `\(name)` | \(modules) | \(depsStr) | \(checkoutStr) | \(artifactStr) | \(binaryStr) | \(buildStr) |")
}

lines.append("")
lines.append("¹ Checkout weight: disk space in `.build/checkouts/<dep>`. Fetched on first `swift package resolve` **regardless of trait set**.")
lines.append("")
lines.append("² Artifact MB: `.build/artifacts/llama.swift` — the pre-built llama.cpp xcframework. Downloaded on first resolve regardless of trait set.")
lines.append("")
lines.append("³ Approx. binary delta: sum of stripped `.o` sizes for the specific modules each trait adds, measured from a release build on arm64 macOS. Not the total build delta vs a baseline — shared infrastructure (ManifoldInference, ManifoldRuntime, etc.) is excluded and counted once. Not the final linked binary size — dead-stripping by the app linker typically reduces this further. `Macros` shows 0 because swift-syntax compiles as a build-time compiler plugin (host executable), not a runtime library. `Llama` shows 8 KB because LlamaSwift is a prebuilt xcframework (the 617 MB xcframework column reflects its actual link-time cost).")
lines.append("")
lines.append("⁴ Approx. cold-build delta: wall-clock seconds added to a release build on Apple Silicon (`.build/{debug,release,build.db}` wiped between runs; `.build/checkouts` and `.build/artifacts` kept warm). Variance ±10–20 s on a loaded machine.")
lines.append("")
lines.append("<!-- END GENERATED -->")

// ── named combinations section (generated) ────────────────────────────────

lines.append("")
lines.append("<!-- BEGIN GENERATED COMBINATIONS -->")
lines.append("")
lines.append("## Named build-mode combinations")
lines.append("")
lines.append("These map to the modes in `scripts/build-modes.sh`. Costs here are **not** the sum of individual rows — shared infrastructure is compiled once.")
lines.append("")
lines.append("| Mode | Traits enabled | Approx. checkout+artifact MB¹ | Notes |")
lines.append("|------|----------------|-------------------------------|-------|")
lines.append("| **FoundationOnly** | `FoundationOnly` | ~\(checkoutTotal) cloned, ~0 compiled | ≤5 MB compiled; all ~\(checkoutTotal + artifactTotal) MB fetched once |")
lines.append("| **local-only** (default) | `MLX`, `Llama`, `HuggingFace` | ~\(checkoutTotal) cloned | Default when no `traits:` override; on-device only |")
lines.append("| **cloud-only** | `CloudSaaS` or `Ollama` | ~\(checkoutTotal) cloned | Pure HTTP; no local model deps compiled |")
lines.append("| **full** | all non-Fuzz traits | ~\(checkoutTotal) cloned | ~\(artifactTotal) MB xcframework + Metal compile |")
lines.append("")
lines.append("¹ All modes clone the same ~\(checkoutTotal) MB of source checkouts plus the ~\(artifactTotal) MB llama.cpp xcframework on first resolve. The FoundationOnly mode _compiles_ ~5 MB. See footnote 1 in the table above and the resolution note.")
lines.append("")
lines.append("<!-- END GENERATED COMBINATIONS -->")

let output = lines.joined(separator: "\n")
print(output)

// Also write to outPath marker so the shell can detect success
try? output.write(toFile: outPath + ".generated", atomically: true, encoding: .utf8)
SWIFT
    )

    local TMP
    TMP=$(mktemp -t measure-trait-costs.XXXXXX.swift)
    trap 'rm -f "$TMP"' RETURN
    printf '%s' "$RENDER_SWIFT" > "$TMP"

    GENERATED=$(swift "$TMP" "$json" "$out")
    rm -f "${out}.generated" 2>/dev/null || true

    # Write the full markdown document combining the generated table with the
    # hand-written prose sections.
    write_full_doc "$GENERATED" "$out"
    log "Wrote $out"
}

write_full_doc() {
    local generated_content="$1"
    local out="$2"

    cat > "$out" <<'PREAMBLE'
# ManifoldKit — Per-trait cost table

> **Generated document.** The table sections are regenerated from `docs/trait-costs.json`
> by `scripts/measure-trait-costs.sh`. The "Why the clone is heavy" section is
> hand-written prose (marked below). Do not edit the `BEGIN GENERATED` … `END GENERATED`
> regions by hand — re-run the script instead. `TraitCostsDriftTest` fails CI if
> the generated regions drift from the JSON.

PREAMBLE

    printf '%s\n' "$generated_content" >> "$out"

    cat >> "$out" <<'PROSE'

---

<!-- BEGIN HAND-WRITTEN — edit freely; drift test does not cover this section -->

## Why the clone is heavy — and what we're doing about it

### The resolution gap in SwiftPM traits

SwiftPM trait support ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md), landed Swift 6.1) gates *compilation* and *linking* — whether a target is compiled and whether a library product is linked into your binary. It does **not** gate dependency *resolution*: every `.package(url:)` entry in `Package.swift` is cloned into `.build/checkouts` on first `swift package resolve`, regardless of the active trait set.

SE-0450 explicitly calls out fetch-pruning as a "Future direction" that was descoped from the initial implementation. Binary targets ([SE-0305](https://github.com/apple/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md)) download the artifact-bundle index eagerly and fetch xcframeworks unconditionally — the index-based conditional fetch mechanism only helps executable plugins, not Apple-platform libraries.

**What this means in practice:** even a `FoundationOnly` consumer (no MLX, no Llama, no HuggingFace) clones ~259 MB of source checkouts and downloads the ~617 MB llama.cpp xcframework on first resolve. The *compiled* artifact is still ≤5 MB (CI-enforced by `scripts/check-foundation-only-bundle.sh` and the `foundation-only-build` CI gate). The binary you ship to the App Store is bounded by what the linker pulls in — not by what SwiftPM cloned.

### App Store reality

The checkout weight is a **one-time developer machine cost** (and a CI cache line), not a user-visible cost. What the user downloads is the stripped, dead-stripped App Store binary. For `FoundationOnly` builds that is verifiably ≤5 MB for the ManifoldBackends module.

**Important runtime note:** Apple's App Store Review Guidelines §2.5.2 prohibit downloading executable code at runtime. Model *weights* are fine; inference *runtimes* must ship in the app bundle. That's why the slim `FoundationOnly` packaging matters for indie apps: the Apple Foundation Models runtime is provided by the OS at zero bundle cost, making it the only inference path where the runtime itself doesn't add to your IPA.

See [docs/AppStoreSubmission.md](AppStoreSubmission.md) for the full submission checklist, including the encryption-export classification and privacy-manifest requirements for each build mode.

### Roadmap candidates under evaluation

These are directions under active evaluation — **not commitments**. ManifoldKit's module seams are already cut to make them tractable:

**(a) Satellite packages for heavy families.** The only resolution-pruning mechanism SwiftPM has today is moving a dependency into a separate package that consumers opt into explicitly (the Vapor/onnxruntime-gpu pattern). `ManifoldMLX`, `ManifoldLlama`, and `ManifoldCloud` already depend on `ManifoldInference` (or `ManifoldContract`) directly and carry zero cross-family symbols — the seams exist. The cost is an extra `.package(url:)` line in consumer manifests and a separate release cadence.

**(b) Prebuilt mlx-swift xcframework.** The dominant cold-build cost on Apple Silicon is compiling mlx-swift's Metal shaders (~117 MB checkout, ~100 MB compiled with Metal shader IR). Firebase/Google ship their ML SDKs as prebuilt xcframeworks to avoid exactly this. If ml-explore publishes a prebuilt xcframework tag, ManifoldKit can switch `mlx-swift` to a binary target and eliminate the Metal compile entirely for consumers. Tracked in umbrella issue #1002.

**(c) Adopt toolchain trait-pruning when it ships.** SE-0450 names fetch-pruning as an explicit future direction. When it lands in a Swift toolchain that ManifoldKit's minimum deployment supports, dependency-attributed checkout weights (the table above) will drop toward zero for traits the consumer hasn't enabled. No code changes required on ManifoldKit's side — the `Package.swift` trait declarations are already the right shape.

<!-- END HAND-WRITTEN -->
PROSE

    log "Full markdown document written to $out"
}

render_markdown "$JSON_OUT" "$MD_OUT"

log ""
log "Done. Outputs:"
log "  $JSON_OUT"
log "  $MD_OUT"
