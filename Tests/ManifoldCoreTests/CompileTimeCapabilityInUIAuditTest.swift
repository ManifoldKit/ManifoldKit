import XCTest
import Darwin

/// Guards against regressions on the `DownloadableModelRow` defect (fixed in
/// the same PR that adds this audit): a UI view reading `CompiledBackends` —
/// the compile-time backend-family contract — to decide whether a *model
/// type* (GGUF/MLX/…) is available.
///
/// ## Why this matters
///
/// `CompiledBackends.current` reports only backends compiled into THIS
/// build. MLX and llama.cpp register at RUNTIME from the companion packages
/// (manifold-mlx / manifold-llama, #1749) and are, BY CONSTRUCTION, never in
/// `CompiledBackends.detected()` — so a UI view that reads
/// `CompiledBackends.current.compatibility(for:)` (or any of its properties)
/// to gate a model-type row reports every GGUF/MLX row as unavailable even
/// when the companion is installed and the backend is registered with the
/// live `ModelRegistry`/`InferenceService`. This shipped and reached a real
/// app (`fireside`) before being caught — see
/// `Sources/ManifoldUIModelManagement/Views/Models/DownloadableModelRow.swift`.
///
/// The fix threads a `ModelRegistry` (or a host-injected
/// `FrameworkCapabilityService`, which itself ultimately reads the live
/// `InferenceService`) into the view instead. `CompiledBackends` still has
/// LEGITIMATE uses in this layer — a genuine build-time fact like "is the
/// HuggingFace product even linked in" (a trait/product either compiles or
/// it doesn't; no runtime registration can change that) — so this audit does
/// not ban the type outright. It requires every reference to be explicitly
/// justified with an inline marker, exactly like `ScriptFailOpenAuditTest`'s
/// `# fail-open-ok: <reason>` for shell scripts.
///
/// ## What this test enforces
///
/// Scans `Sources/ManifoldUI/`, `Sources/ManifoldUIModelManagement/`, and
/// `Sources/ManifoldVoice/` (enumerated explicitly — NOT a
/// `hasPrefix("Sources/ManifoldUI")` test, which would double-count
/// `ManifoldUIModelManagement` under `ManifoldUI`'s scan). On every
/// NON-COMMENT line:
///
/// 1. **Unmarked reference** — the line contains `CompiledBackends`
///    (case-insensitive, so it also catches the lowercase-first-letter
///    `compiledBackends` property/parameter spelling) and neither that line
///    nor the line immediately above it carries
///    `// compile-time-capability-ok: <reason>` with a non-empty reason.
/// 2. **Bare marker** — the marker text is present but with no colon, or a
///    colon with nothing (or only whitespace) after it. Flagged in its own
///    right — same hazard (a free, invisible opt-out) and remedy as
///    `ScriptFailOpenAuditTest`'s bare `|| true`.
///
/// ## What this audit CANNOT catch
///
/// A1 (this audit) only catches a compile-time *read*. It cannot catch A2's
/// shape — a caller passing a hardcoded `Bool` that CLAIMS runtime
/// availability without actually deriving it from anything live (e.g. a
/// `hasEmbeddingBackend: false` argument that never reflects whether an
/// embedding backend is actually loaded). That is a data-flow property, not
/// a lexical one; `DocumentLibraryEmbeddingSignalTests` covers it instead.
///
/// The detection function is `violations(sourceRoots:repoRoot:)`, shared by
/// this audit and its own in-file sabotage test.
final class CompileTimeCapabilityInUIAuditTest: XCTestCase {

    func test_noUnmarkedCompiledBackendsReadsInUILayer() throws {
        let repoRoot = try Self.locateRepoRoot()
        let sourceRoots = try Self.scanRoots(repoRoot: repoRoot)

        let violations = try Self.violations(sourceRoots: sourceRoots, repoRoot: repoRoot)

        if !violations.isEmpty {
            let formatted = violations.map { "  \($0)" }.joined(separator: "\n")
            XCTFail("""
                Unmarked or bare-marked `CompiledBackends` reference(s) detected in the UI layer.

                `CompiledBackends.current` reports only backends compiled into THIS build.
                MLX/llama.cpp register at RUNTIME from the companion packages and are never
                visible to a compile-time read (#1749) — a UI view that gates a model-type
                row on `CompiledBackends` alone reports every GGUF/MLX row unavailable even
                when the companion is installed and registered. See
                Sources/ManifoldUIModelManagement/Views/Models/DownloadableModelRow.swift
                for the fixed shape (thread a `ModelRegistry` / `FrameworkCapabilityService`
                instead), and mark genuinely build-time-only reads with
                `// compile-time-capability-ok: <reason>` on the line itself or the line
                directly above.

                Violations (file:line — kind):
                \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `violations(sourceRoots:repoRoot:)` the audit runs)

    /// Plants a temp tree shaped like the three scan roots with four files and
    /// asserts the REAL detection function flags exactly the two bad ones.
    func test_sabotage_flagsUnmarkedAndBareMarkedCompiledBackendsReads() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "compile-time-capability-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sourcesRoot = tmp.appendingPathComponent("Sources", isDirectory: true)
        let uiRoot = sourcesRoot.appendingPathComponent("ManifoldUI", isDirectory: true)
        try FileManager.default.createDirectory(at: uiRoot, withIntermediateDirectories: true)

        // Bad.swift — unmarked read, must be flagged.
        let badFile = uiRoot.appendingPathComponent("Bad.swift")
        try """
        import SwiftUI
        struct Bad: View {
            var body: some View {
                let compat = CompiledBackends.current.compatibility(for: .gguf)
                return Text(compat.isSupported ? "yes" : "no")
            }
        }
        """.write(to: badFile, atomically: true, encoding: .utf8)

        // Good.swift — marked with a real reason, must NOT be flagged.
        let goodFile = uiRoot.appendingPathComponent("Good.swift")
        try """
        import SwiftUI
        struct Good: View {
            // compile-time-capability-ok: HuggingFace product is either linked in or it isn't — a genuine build-time fact.
            var linksHuggingFace: Bool { CompiledBackends.current.traits.contains(.huggingFace) }
            var body: some View { Text("ok") }
        }
        """.write(to: goodFile, atomically: true, encoding: .utf8)

        // Bare.swift — marker present but empty reason, must be flagged.
        let bareFile = uiRoot.appendingPathComponent("Bare.swift")
        try """
        import SwiftUI
        struct Bare: View {
            // compile-time-capability-ok:
            var compiled: CompiledBackends { .current }
            var body: some View { Text("bare") }
        }
        """.write(to: bareFile, atomically: true, encoding: .utf8)

        // Prose.swift — doc-comment-only mention, must NOT be flagged (comment lines
        // are excluded from the scan entirely, regardless of marker presence).
        let proseFile = uiRoot.appendingPathComponent("Prose.swift")
        try """
        import SwiftUI
        /// Historical note: this view used to read `CompiledBackends.current` directly.
        /// See DownloadableModelRow.swift for why that was wrong.
        struct Prose: View {
            var body: some View { Text("prose") }
        }
        """.write(to: proseFile, atomically: true, encoding: .utf8)

        let violations = try Self.violations(sourceRoots: [uiRoot], repoRoot: tmp).sorted()
        XCTAssertEqual(violations.count, 2, "Exactly the unmarked and bare-marked reads must be flagged")
        XCTAssertEqual(violations, [
            "Sources/ManifoldUI/Bad.swift:4 — unmarked",
            "Sources/ManifoldUI/Bare.swift:4 — bare marker",
        ])
    }

    // MARK: - Detection

    /// Full audit pipeline: walk each root in `sourceRoots`, collect every
    /// non-comment `CompiledBackends` occurrence (case-insensitive) that lacks
    /// an adjacent `compile-time-capability-ok` marker with a real reason, or
    /// whose marker is bare. Both the audit and the sabotage test call this.
    ///
    /// - Returns: `"<relative/path/from/repoRoot>:<line> — <unmarked | bare marker>"`.
    static func violations(sourceRoots: [URL], repoRoot: URL) throws -> [String] {
        var violations: [String] = []

        for root in sourceRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let swiftFiles = try Self.enumerateSwiftFiles(under: root)

            for fileURL in swiftFiles {
                let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                let relativePath = Self.relativePath(of: fileURL, under: repoRoot)
                let lineViolations = Self.findViolations(in: content)
                for (lineNumber, kind) in lineViolations {
                    violations.append("\(relativePath):\(lineNumber) — \(kind)")
                }
            }
        }

        return violations
    }

    /// Returns `(1-based line, kind)` pairs for every non-comment
    /// `CompiledBackends` occurrence that is unmarked or bare-marked.
    private static func findViolations(in content: String) -> [(Int, String)] {
        let lines = content.components(separatedBy: "\n")
        var result: [(Int, String)] = []

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if Self.isCommentLine(trimmed) { continue }
            guard trimmed.lowercased().contains("compiledbackends") else { continue }

            let selfMarker = Self.markerState(of: trimmed)
            let aboveMarker: MarkerState
            if index > 0 {
                aboveMarker = Self.markerState(of: lines[index - 1].trimmingCharacters(in: .whitespaces))
            } else {
                aboveMarker = .absent
            }

            switch (selfMarker, aboveMarker) {
            case (.present, _), (_, .present):
                continue // marked with a real reason — not a violation
            case (.bare, _), (_, .bare):
                result.append((index + 1, "bare marker"))
            case (.absent, .absent):
                result.append((index + 1, "unmarked"))
            }
        }

        return result
    }

    private enum MarkerState {
        case absent
        case bare
        case present
    }

    private static let markerNeedle = "compile-time-capability-ok"

    /// Classifies a single trimmed line's marker state. A line not containing
    /// the marker needle at all is `.absent`; a line containing it followed by
    /// a colon and a non-empty (non-whitespace) reason is `.present`; anything
    /// else containing the needle (no colon, or colon with nothing after it)
    /// is `.bare`.
    private static func markerState(of trimmedLine: String) -> MarkerState {
        guard let range = trimmedLine.range(of: markerNeedle) else { return .absent }
        let rest = trimmedLine[range.upperBound...]
        guard let colonIndex = rest.firstIndex(of: ":") else { return .bare }
        let reason = rest[rest.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? .bare : .present
    }

    private static func isCommentLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*")
    }

    // MARK: - Helpers (mirrors UserDefaultsStandardAuditTest's helpers)

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "CompileTimeCapabilityInUIAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate the repo root (a directory containing Sources/) from #filePath",
        ])
    }

    /// The three scan roots, enumerated explicitly — never a
    /// `hasPrefix("Sources/ManifoldUI")` test, which would double-count
    /// `Sources/ManifoldUIModelManagement` under the `ManifoldUI` scan.
    private static func scanRoots(repoRoot: URL) throws -> [URL] {
        [
            repoRoot.appendingPathComponent("Sources/ManifoldUI", isDirectory: true),
            repoRoot.appendingPathComponent("Sources/ManifoldUIModelManagement", isDirectory: true),
            repoRoot.appendingPathComponent("Sources/ManifoldVoice", isDirectory: true),
        ]
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    private static func relativePath(of fileURL: URL, under root: URL) -> String {
        let filePath = fileURL.path
        let rootPath = root.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    /// Builds a fresh, UUID-suffixed temp directory and returns it fully
    /// resolved via POSIX `realpath()`. `/var` (macOS's temp-dir root) is an
    /// APFS firmlink to `/private/var`, not a classic symlink — so
    /// `URL.resolvingSymlinksInPath()` leaves it untouched while
    /// `FileManager`'s directory enumerator returns the fully-resolved
    /// `/private/var/...` form for every child it walks. Without this,
    /// string-prefix stripping of `root.path` against an enumerated child's
    /// `.path` silently fails to match (the prefixes differ), corrupting
    /// every relative-path fingerprint this sabotage test asserts against.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
