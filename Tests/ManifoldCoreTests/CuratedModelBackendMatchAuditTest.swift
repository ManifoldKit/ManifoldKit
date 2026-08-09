import XCTest
import Foundation

/// Audit: each Example app's curated-model list may only contain entries
/// whose `modelType` matches a companion backend that target actually links.
///
/// Regression test for the wart fixed in #2453 M2: `Example/Advanced/
/// ManifoldDemoApp.swift` used to populate `CuratedModel.all` with five
/// GGUF/MLX entries while linking neither `ManifoldLlama` nor `ManifoldMLX` —
/// every entry was unloadable, because `ModelRegistry.compatibility(for:)`
/// never resolves `.isSupported` for a `modelType` with no registered
/// backend. The fix deleted Advanced's list outright and moved a corrected,
/// actually-loadable MLX-only list to `LocalInferenceExample_MLX`, the new
/// target that links `ManifoldMLX`.
///
/// This is a source-text audit, not a `@testable import`: `Example/` is a
/// separate XcodeGen/Xcode project, not a SwiftPM target, so nothing in
/// `swift test` compiles it. The audit reads the known app source files
/// directly off disk and regex-matches each `CuratedModel(...)` call's `id:`
/// and `modelType:` arguments.
final class CuratedModelBackendMatchAuditTest: XCTestCase {

    /// Hand-kept map — mirrors the `scripts/*.sh` → suite mapping convention
    /// documented in AGENTS.md's "Documentation gates" section (no automatic
    /// tripwire for a forgotten entry; if that keeps happening the fix is a
    /// broader file-discovery pass, same as noted there). Relative path from
    /// repo root → the `modelType` raw tokens (`CuratedModel.modelType`'s
    /// case names) that file's linked companion backend(s) can actually load.
    /// An empty set means the target links no local-inference companion, so
    /// NO `CuratedModel` entry is ever loadable there.
    static let allowedModelTypesByFile: [String: Set<String>] = [
        "Example/Advanced/ManifoldDemoApp.swift": [],
        "Example/Examples/LocalInferenceExample/MLX/LocalInferenceExampleMLXApp.swift": ["mlx"],
        "Example/Examples/LocalInferenceExample/Llama/LocalInferenceExampleLlamaApp.swift": ["gguf"],
    ]

    func test_curatedModelLists_matchLinkedBackendPerTarget() throws {
        let root = try Self.locateRepoRoot()
        for (relativePath, allowed) in Self.allowedModelTypesByFile.sorted(by: { $0.key < $1.key }) {
            let fileURL = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("Expected app source file not found: \(relativePath) — update allowedModelTypesByFile if it moved or was renamed.")
                continue
            }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let mismatches = Self.mismatchedEntries(in: source, allowedModelTypes: allowed)
            XCTAssertTrue(
                mismatches.isEmpty,
                "\(relativePath): CuratedModel entries with an unloadable modelType " +
                    "(no matching linked backend in this target): \(mismatches.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Sabotage (Principle 4 / AuditSabotageCoverageAuditTest)

    /// Plants a GGUF entry against an MLX-only allowlist and confirms the
    /// real detection function (`mismatchedEntries(in:allowedModelTypes:)`,
    /// the exact function `test_curatedModelLists_matchLinkedBackendPerTarget`
    /// calls) flags it.
    func test_sabotage_mismatchedEntryIsDetected() {
        let source = """
            CuratedModel(
                id: "sabotage-entry",
                displayName: "Sabotage",
                fileName: "sabotage.gguf",
                repoID: "example/sabotage",
                modelType: .gguf,
                approximateSizeBytes: 1_000_000_000,
                recommendedFor: [.small],
                contextSize: 2048,
                promptTemplate: .llama3,
                description: "Deliberately wrong modelType for an MLX-only target."
            )
            """
        let mismatches = Self.mismatchedEntries(in: source, allowedModelTypes: ["mlx"])
        XCTAssertEqual(mismatches, ["sabotage-entry: .gguf"])

        // Same fixture against a GGUF-allowed target must NOT flag — proves
        // the predicate isn't unconditionally failing.
        XCTAssertTrue(Self.mismatchedEntries(in: source, allowedModelTypes: ["gguf"]).isEmpty)
    }

    // MARK: - Detection

    /// Extracts every `CuratedModel(id: "...", ..., modelType: .xxx, ...)`
    /// entry from `source` and returns `"<id>: .<modelType>"` for any whose
    /// modelType is not in `allowedModelTypes`.
    ///
    /// Deliberately tolerant of argument order and whitespace — `id:` and
    /// `modelType:` are matched independently within each `CuratedModel(...)`
    /// call's body, not positionally, so reordering the initializer's
    /// argument list upstream doesn't silently blind this audit.
    static func mismatchedEntries(in source: String, allowedModelTypes: Set<String>) -> [String] {
        var results: [String] = []
        for block in curatedModelBlocks(in: source) {
            guard let id = firstCapture(pattern: #"id:\s*"([^"]+)""#, in: block),
                  let modelType = firstCapture(pattern: #"modelType:\s*\.(\w+)"#, in: block) else {
                continue
            }
            if !allowedModelTypes.contains(modelType) {
                results.append("\(id): .\(modelType)")
            }
        }
        return results
    }

    /// Splits `source` into the balanced-parenthesis body of every top-level
    /// `CuratedModel(...)` call — a plain substring search rather than a
    /// SwiftSyntax parse, matching the rest of this repo's source-text audits
    /// (e.g. `SilentCatchAuditTest`).
    static func curatedModelBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var searchStart = source.startIndex
        while let range = source.range(of: "CuratedModel(", range: searchStart..<source.endIndex) {
            var depth = 1
            var index = range.upperBound
            let bodyStart = index
            while index < source.endIndex, depth > 0 {
                let char = source[index]
                if char == "(" { depth += 1 }
                if char == ")" { depth -= 1 }
                index = source.index(after: index)
            }
            if depth == 0 {
                let bodyEnd = source.index(before: index)
                blocks.append(String(source[bodyStart..<bodyEnd]))
            }
            searchStart = index
        }
        return blocks
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    /// Walks upward from this file to the repo root (the directory that
    /// contains both `Package.swift` and `Example/`).
    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let manifest = dir.appendingPathComponent("Package.swift")
            let example = dir.appendingPathComponent("Example")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: manifest.path),
               FileManager.default.fileExists(atPath: example.path, isDirectory: &isDir),
               isDir.boolValue {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "CuratedModelBackendMatchAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift + Example/) from #filePath",
        ])
    }
}
