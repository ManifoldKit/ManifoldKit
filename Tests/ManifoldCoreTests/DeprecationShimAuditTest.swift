import XCTest

/// Audit: production sources must not carry `@available(*, deprecated …)`.
///
/// AGENTS.md § "Public API design policy (pre-1.0)" is explicit:
/// **"Pre-1.0, delete — don't deprecate."** `@available(*, deprecated)` is a
/// post-1.0 tool for giving external consumers a migration window; before 1.0
/// there is no stability promise to protect, so a retired API is removed
/// outright rather than carried forward as a shim.
///
/// That rule had no tripwire, and nine shims accumulated behind it — one per
/// "I'll clean it up later", each individually defensible. What they cost,
/// concretely, when this audit was written:
///
/// * `SeedModelError` had exactly one case, marked unreachable since v0.48,
///   and was **never thrown anywhere**. It survived the inert-surface audit
///   because `inert-surface-allowlist.txt` exempted it with the reason
///   "thrown by `quickStart(seed:)`; caught downstream" — which was false.
/// * `OllamaBackend.makeChecked` carried a deprecation whose message read
///   "use makeChecked(urlSession:)" — it pointed at itself, having been
///   copy-pasted from the initializer above it, so a consumer following that
///   initializer's own migration advice got an unactionable warning either way.
/// * Two SwiftUI views kept an entire second construction path alive
///   (`RegistrySource.environment` + a private `EnvironmentBridge`) whose only
///   writers were the deprecated initializers.
///
/// So this is not style enforcement: a deprecation shim is a read path whose
/// writer is gone, and Principle 10 ("shipped means live") says that lies to
/// every future reader.
///
/// **Deliberately zero-tolerance, with no allowlist.** Pre-1.0 there is no
/// legitimate case, and an allowlist is precisely how the inert-surface audit
/// was defeated above. When the project reaches 1.0 and deprecation becomes
/// the correct tool, this audit is deleted or inverted in the same PR that
/// changes the policy — not quietly exempted.
///
/// Scope notes, all deliberate:
///
/// * `@available(macOS 26, *)` and other *platform* availability is untouched.
/// * `@available(macOS, deprecated: 26.0)` — a platform-scoped deprecation — is
///   also not flagged. The rule is about carrying a retired API forward for
///   consumers, not about OS-version annotations.
/// * `@available(*, unavailable, …)` is not flagged either. A tombstone that
///   turns a removed API into a compile *error* (e.g.
///   `RAGEvaluator.swift`'s `#1937` marker) is the opposite of a shim: it
///   refuses the call instead of quietly accepting it.
/// * Known limitation: the scan is textual, so a wrapped `@available(` …
///   `*, deprecated` inside a multi-line **string literal** under `Sources/`
///   would be flagged with no exemption path. No such file exists today; if
///   one is ever added, teach the scan about `"""` regions rather than
///   introducing an allowlist.
final class DeprecationShimAuditTest: XCTestCase {

    func test_noDeprecationShimsInProductionSources() throws {
        let sources = try Self.locateSourcesDirectory()
        let offenders = try Self.scanForDeprecationShims(in: sources)

        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders.count) `@available(*, deprecated …)` declaration(s) found in Sources/. \
            AGENTS.md § Public API design policy (pre-1.0): delete the API, don't deprecate it — \
            and delete whatever code paths only the retired declaration reached. If a removal \
            genuinely cannot happen yet, that is a design discussion for the PR, not a shim. \
            Demoting to `package` is one option, but screen it first with \
            scripts/api-demotion-screen.sh: OllamaBackend.init(urlSession:) was demoted in an \
            earlier draft of this very sweep and it broke a shipping consumer. Offenders:
            \(offenders.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Sabotage

    /// Principle 4: plant the violation this audit exists to catch and run the
    /// audit's own detection function against it. Without this, a scan whose
    /// path resolution silently broke — or whose regex stopped matching —
    /// would report "0 offenders" forever and read exactly like success.
    func test_sabotage_scanFlagsPlantedDeprecation() throws {
        // `temporaryDirectory` is `/var/folders/…`, an APFS firmlink to
        // `/private/var/folders/…`, and the enumerator yields the resolved
        // form. Resolve the *root* before appending — `resolvingSymlinksInPath()`
        // cannot resolve a component that does not exist yet, so calling it on
        // the full not-yet-created path is a no-op. See `relativePath(of:under:)`
        // for why the comparison resolves both sides too.
        let tmp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("deprecation-shim-sabotage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: tmp) } catch {
                // Best-effort temp cleanup; nothing to assert on.
            }
        }

        // Nested, so the sabotage also proves the walk actually recurses
        // rather than reading one flat directory.
        let nested = tmp.appendingPathComponent("ManifoldFake/Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        import Foundation

        public struct Planted {
            @available(*, deprecated, renamed: "replacement")
            public var oldName: Int { replacement }

            public var replacement: Int { 0 }
        }
        """.write(to: nested.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)

        // A clean file, and platform availability, must NOT be flagged —
        // otherwise the audit would be "fails on everything", which detects
        // nothing either.
        try """
        import Foundation

        @available(macOS 26, iOS 26, *)
        public struct PlatformGated {
            public var value: Int { 0 }
        }
        """.write(to: nested.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)

        // The wrapped form: `@available(` and `*, deprecated` on separate
        // lines. swift-format produces this on long messages, so a
        // single-line matcher would silently miss real shims.
        try """
        import Foundation

        public struct Wrapped {
            @available(
                *,
                deprecated,
                message: "A message long enough that a formatter wraps the attribute across lines."
            )
            public var oldName: Int { 0 }
        }
        """.write(to: nested.appendingPathComponent("Wrapped.swift"), atomically: true, encoding: .utf8)

        let offenders = try Self.scanForDeprecationShims(in: tmp)

        XCTAssertEqual(offenders.count, 2, "Both the inline and the wrapped deprecation must be flagged, got: \(offenders)")
        XCTAssertEqual(offenders.first?.file, "ManifoldFake/Deep/Planted.swift")
        XCTAssertEqual(offenders.first?.line, 4, "Expected the attribute's own line number")
        XCTAssertTrue(
            offenders.contains { $0.file.hasSuffix("Wrapped.swift") && $0.line == 4 },
            "A multi-line `@available(` … `*, deprecated` must be flagged at the attribute's opening line, got: \(offenders)"
        )
        XCTAssertFalse(
            offenders.contains { $0.file.hasSuffix("Clean.swift") },
            "Platform availability is not a deprecation shim and must not be flagged"
        )
    }

    // MARK: - Detection

    struct Offender: CustomStringConvertible, Equatable {
        let file: String
        let line: Int
        var description: String { "\(file):\(line)" }
    }

    /// Scans every `*.swift` under `root` for the deprecation-shim spelling.
    /// Shared by the real audit and the sabotage above — the sabotage is only
    /// meaningful because it exercises this exact function.
    static func scanForDeprecationShims(in root: URL) throws -> [Offender] {
        var offenders: [Offender] = []
        // Strip against the *resolved* root: the enumerator yields resolved
        // paths, so an unresolved root (a `/var/folders/…` firmlink) would fail
        // to match and mangle every relative path. Belt-and-braces with the
        // caller resolving its own root — this function should not depend on
        // the caller having done so.
        let rootPath = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "DeprecationShimAudit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not enumerate \(root.path)",
            ])
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard contents.contains("deprecated") else { continue }   // cheap pre-filter
            let lines = contents.components(separatedBy: .newlines)
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // Match the attribute, not prose mentioning it: a doc comment
                // explaining why something WAS deprecated is legitimate and
                // common in this repo (several of the deletions left exactly
                // such a note behind), so comment lines are skipped.
                guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("*") else { continue }
                guard line.contains("@available(") else { continue }

                // The attribute may wrap across lines — `@available(` on one,
                // `*, deprecated, message: …` on the next — which a
                // single-line match would sail past. swift-format produces
                // exactly that shape on long messages, so this is a realistic
                // evasion, not a hypothetical. Join from the attribute to its
                // closing paren (bounded, so a stray `@available(` can't run
                // away to end-of-file) and match the joined text.
                var joined = line
                var lookahead = index
                while !joined.contains(")"), lookahead + 1 < lines.count, lookahead - index < 8 {
                    lookahead += 1
                    joined += " " + lines[lookahead].trimmingCharacters(in: .whitespaces)
                }
                let normalized = joined.replacingOccurrences(of: " ", with: "")
                guard normalized.contains("@available(*,deprecated") else { continue }
                let relative = Self.relativePath(of: url, under: rootPath)
                offenders.append(Offender(file: relative, line: index + 1))
            }
        }
        return offenders.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// Path of `url` relative to `rootPath`, resolving symlinks on BOTH sides
    /// before comparing.
    ///
    /// A plain `replacingOccurrences(of: root + "/")` is wrong here and failed
    /// twice: `temporaryDirectory` is `/var/folders/…` while the enumerator
    /// yields `/private/var/folders/…`, so the unresolved root matches as an
    /// *infix* of the resolved path and strips the middle, yielding
    /// "/privateManifoldFake/Deep/Planted.swift". Prefix-drop on two resolved
    /// paths is the only form that cannot do that.
    static func relativePath(of url: URL, under rootPath: String) -> String {
        let resolved = url.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if resolved.hasPrefix(prefix) {
            return String(resolved.dropFirst(prefix.count))
        }
        // Not under the root after resolution — report the full path rather
        // than a silently mangled one.
        return resolved
    }

    /// Walks up from this file to the package root, then returns `Sources/`.
    /// Mirrors `ScriptFailOpenAuditTest.locateScriptsDirectory()` — anchoring
    /// on `Package.swift` keeps this working under worktrees and CI checkouts
    /// where the absolute path differs.
    private static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let manifest = dir.appendingPathComponent("Package.swift")
            let sources = dir.appendingPathComponent("Sources")
            if FileManager.default.fileExists(atPath: manifest.path),
               FileManager.default.fileExists(atPath: sources.path) {
                return sources
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "DeprecationShimAudit", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath",
        ])
    }
}
