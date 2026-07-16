#!/usr/bin/env bash
# render-feature-matrix.sh — render docs/FeatureMatrix.md from FeatureMatrix.swift.
#
# Why not call FeatureMatrix.markdown() directly?
# Calling a public static method on a library target from a shell script
# requires either (a) a dedicated executable target (heavyweight — pulls the
# whole ManifoldKit graph into a build product no consumer uses) or
# (b) `swift -e` with cross-target imports (brittle, no module path).
#
# Instead this script regexes the Swift source. The matrix entries follow a
# stable shape (`ManifoldTrait(\n    name: "X",\n    description: "...",\n
# unlocks: [...])`) and `FeatureMatrixTests` asserts that the rendered file
# matches what `FeatureMatrix.markdown()` produces — so drift between this
# script and the canonical Swift implementation fails CI.
#
# Output:
# - prints the markdown to stdout
# - writes docs/FeatureMatrix.md
#
# Usage:
#   scripts/render-feature-matrix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/ManifoldKit/FeatureMatrix.swift"
OUT="$ROOT/docs/FeatureMatrix.md"

if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

mkdir -p "$ROOT/docs"

# Parse the Swift source with a tiny Swift one-liner — `Foundation` regex is
# more reliable than awk for multi-line struct literals, and we don't need
# to depend on the rest of the module graph.
RENDER_SWIFT=$(cat <<'SWIFT'
import Foundation

let path = CommandLine.arguments[1]
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    fputs("error: cannot read \(path)\n", stderr)
    exit(1)
}

struct Trait {
    let name: String
    let description: String
    let unlocks: [String]
}

// Match: ManifoldTrait(\n    name: "X",\n    description: "...",\n    unlocks: [...]
// Description string can contain escaped quotes; we permit them by matching
// any char except an unescaped closing quote.
let pattern = #"ManifoldTrait\s*\(\s*name:\s*"([^"]+)"\s*,\s*description:\s*"((?:[^"\\]|\\.)*)"\s*,\s*unlocks:\s*\[([^\]]*)\]"#
let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
let range = NSRange(source.startIndex..., in: source)

var traits: [Trait] = []
regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
    guard let m = match,
          let nameRange = Range(m.range(at: 1), in: source),
          let descRange = Range(m.range(at: 2), in: source),
          let unlocksRange = Range(m.range(at: 3), in: source) else { return }
    let name = String(source[nameRange])
    let description = String(source[descRange])
        .replacingOccurrences(of: "\\\"", with: "\"")
    let unlocksBody = String(source[unlocksRange])
    let unlocks = unlocksBody
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        .map { $0.replacingOccurrences(of: ".", with: "") }
    traits.append(Trait(name: name, description: description, unlocks: unlocks))
}

traits.sort { $0.name.lowercased() < $1.name.lowercased() }

var lines: [String] = []
lines.append("# ManifoldKit Feature Matrix")
lines.append("")
lines.append("**Audience:** consumer")
lines.append("**Status:** living")
lines.append("")
lines.append("Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.")
lines.append("Do not edit by hand — re-run the script.")
lines.append("")
lines.append("| Trait | Description | Capabilities Unlocked |")
lines.append("|-------|-------------|-----------------------|")
for trait in traits {
    let caps: String
    if trait.unlocks.isEmpty {
        caps = "_(none — harness/build lever)_"
    } else {
        caps = trait.unlocks.map { "`\($0)`" }.joined(separator: ", ")
    }
    let safeDesc = trait.description.replacingOccurrences(of: "|", with: "\\|")
    lines.append("| `\(trait.name)` | \(safeDesc) | \(caps) |")
}
lines.append("")
print(lines.joined(separator: "\n"))
SWIFT
)

TMP=$(mktemp -t render-feature-matrix.XXXXXX.swift)
trap 'rm -f "$TMP"' EXIT
printf '%s' "$RENDER_SWIFT" > "$TMP"

OUTPUT=$(swift "$TMP" "$SRC")
printf '%s\n' "$OUTPUT"
printf '%s\n' "$OUTPUT" > "$OUT"
echo "wrote $OUT" >&2
