import XCTest
import Darwin

/// Guards against a decoy tool name in `DecoyTools.swift` silently colliding
/// with a real, shipped model-facing tool defined anywhere else under
/// `Sources/`.
///
/// ## Why this audit exists, precisely
///
/// `DecoyTools` pads a scenario's advertised toolset (`--extra-tools N`, see
/// that file's doc comment) with plausible-but-irrelevant tool definitions so
/// a scenario run can tell "the model picked the right tool" from "the model
/// had no other tool to pick." `DecoyTools.swift`'s own doc comment asserts
/// its names are drawn from domains orthogonal to every tool it could be
/// advertised alongside — the decoy pool used to define `search_web`, which
/// collides with `ManifoldUI/Tools/WebSearchToolSource.swift`'s shipped
/// `search_web` tool, making that assertion false as written. Fixing the
/// false doc claim is reason enough for this audit on its own.
///
/// **In THIS package today, that collision cannot actually trip:**
/// `ManifoldTools` depends only on `ManifoldInference` (not `ManifoldUI`),
/// and the in-repo `manifold-tools` executable links
/// `ManifoldTools`/`ManifoldOllama`/`ManifoldCloudSaaS`/`ManifoldInference`
/// only — never `ManifoldUI` (see `Package.swift`'s `ManifoldTools` and
/// `manifold-tools` target declarations). So no in-repo driver can advertise
/// both the decoy pool and `WebSearchToolSource`'s real tool in one process,
/// and a scenario sweep run from this repo cannot misscore a correct
/// `search_web` call today. The audit is therefore preventive, not a fix for
/// a currently-live scoring bug — do not read a green run here as evidence
/// this collision was ever actually observed miscoring anything.
///
/// The real reachability path is cross-package: `ManifoldTools` is a
/// published `.library()` product (`Package.swift` products list), so an
/// external consumer — e.g. manifold-eval, or a consumer app driving its own
/// evals — can import both `ManifoldTools` and the `ManifoldKit` umbrella
/// (which re-exports `ManifoldUI`) in one process, at which point the
/// collision this audit blocks becomes live exactly as originally feared.
///
/// The full detection pipeline lives in ``scan(sourcesRoot:)`` so the
/// in-file sabotage test exercises the exact function the audit runs.
///
/// ## Scope
///
/// This audit is deliberately narrow: it only asserts that a name declared
/// in `DecoyTools.swift` does not reappear as a tool name declared anywhere
/// else under `Sources/`. It does NOT assert that no two arbitrary files
/// share a tool name in general — that broader shape was tried while writing
/// this audit and produced no false positives on the current tree, but
/// nothing guarantees it stays that way (e.g. a companion-style forwarding
/// tool that intentionally re-declares an upstream name under a different
/// module), so it is left out rather than risk a noisy, unrelated failure
/// mode blocking unrelated PRs.
///
/// ## Detection shape
///
/// Two declaration shapes are recognized:
///
/// 1. `ToolDefinition(name: "X"` — same-line, or the more common multi-line
///    form where `ToolDefinition(` opens on one line and `name: "X"` is the
///    next non-blank line.
/// 2. `def("X"` — the private helper `DecoyTools.swift` itself uses to build
///    its pool entries.
///
/// Comment lines (`//`, `///`, `*`) are excluded so a DocC example such as
/// ``Sources/ManifoldHardware/ToolTypes.swift``'s `/// name: "get_weather"`
/// is not treated as a live declaration.
///
/// Limitation: this is line-based, not AST-based, matching the sibling
/// audits (`SilentCatchAuditTest`, `TrappingConstructAuditTest`). It only
/// sees STATIC string-literal tool names (`name: "X"` / `def("X"`). A tool
/// name or description assembled at runtime is invisible to it — e.g.
/// `SkillToolSource`'s `invoke_skill` description (built per-registry from
/// discovered `SkillDefinition`s), `HandoffToolSource`'s
/// `"\(HandoffDetector.transferToolPrefix)\(agent.name)"`, `MCPToolSource`'s
/// namespaced tool names, and `AppIntentToolExecutor`'s bridged names. This
/// audit would NOT have caught this same PR's Bug 2 (`SkillToolSource`
/// describing every skill's arguments using only the first skill's hint) —
/// that is a parameter-description authoring bug, not a name collision, and
/// lives entirely inside a per-call runtime string this audit never inspects.
///
/// ## Approval shape
///
/// A colliding declaration outside `DecoyTools.swift` falls through to a
/// path-based allowlist (`tool_name_collision_allowlist.txt`, next to this
/// file), mirroring `SilentCatchAuditTest`. Format: one fingerprint
/// (`relative/path.swift:name`) per line; `#`-prefixed lines and blank lines
/// are ignored. This is for collisions with a tool definition that is not
/// reachable by a real chat session (a fuzz/fixture/test-only toolset) — see
/// the allowlist file's own comment for the one entry it carries as of this
/// PR (`ManifoldFuzz/SyntheticToolset.swift`'s `get_weather`, a pre-existing
/// collision unrelated to the `search_web` bug this audit was added for).
final class ToolNameCollisionAuditTest: XCTestCase {

    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            XCTFail("Failed to load tool_name_collision_allowlist.txt: \(error)")
            return []
        }
    }()

    func test_decoyToolNamesDoNotCollideWithShippedToolNames() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        let declarations = try Self.scan(sourcesRoot: sourcesURL)
        let decoyDeclarations = declarations.filter { $0.file.hasSuffix("DecoyTools.swift") }
        XCTAssertFalse(decoyDeclarations.isEmpty, "Expected to find decoy tool declarations in DecoyTools.swift — detection probably broken")

        let decoyNames = Set(decoyDeclarations.map(\.name))
        let allCollisions = declarations.filter { !$0.file.hasSuffix("DecoyTools.swift") && decoyNames.contains($0.name) }

        var found: Set<String> = []
        var offenders: [ToolNameDeclaration] = []
        for collision in allCollisions {
            let fingerprint = "\(collision.file):\(collision.name)"
            found.insert(fingerprint)
            if !Self.allowlist.contains(fingerprint) {
                offenders.append(collision)
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  name: \"\($0.name)\"" }
                .joined(separator: "\n")
            XCTFail("""
                A DecoyTools.swift decoy name collides with a real tool name declared elsewhere in Sources/.
                A decoy sharing a shipped tool's name means padding a scenario's toolset with decoys can
                silently duplicate a name the model is legitimately allowed to call, misscoring a correct
                call as a decoy invocation. Rename the decoy (keep its position in DecoyTools.pool — see
                that file's fixed-order doc comment) to something outside every shipped tool's domain, or
                if the colliding declaration is a fuzz/fixture/test-only toolset never reachable by a real
                chat session, add its fingerprint to Tests/ManifoldInferenceTests/tool_name_collision_allowlist.txt
                with a one-line justification.

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting.
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                tool_name_collision_allowlist.txt has stale entries that no longer exist as a collision in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(sourcesRoot:)` the audit runs)

    /// Plants a temp source tree with a `DecoyTools.swift`-shaped file
    /// declaring a decoy via `def("...")`, and a separate "shipped tool"
    /// file declaring a real tool via `ToolDefinition(name: "...")` — once
    /// colliding, once not — and asserts the REAL detection pipeline flags
    /// exactly the colliding case.
    func test_sabotage_scanFlagsPlantedCollisionAndIgnoresNonCollision() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "tool-name-collision-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Colliding case: the decoy pool declares "search_web" via def(...),
        // and a separate shipped-tool file declares the same name via the
        // multi-line ToolDefinition(name: "X") form.
        try """
        import Foundation

        enum DecoyTools {
            private static func def(_ name: String) -> Int { 0 }
            private static let pool = [
                def("search_web"),
                def("get_movie_showtimes"),
            ]
        }
        """.write(to: root.appendingPathComponent("DecoyTools.swift"), atomically: true, encoding: .utf8)

        try """
        import Foundation

        struct RealWebSearchTool {
            static let definition = ToolDefinition(
                name: "search_web",
                description: "Searches the web.",
                parameters: .object([:])
            )
        }
        """.write(to: root.appendingPathComponent("RealWebSearchTool.swift"), atomically: true, encoding: .utf8)

        // Non-colliding shipped tool — must NOT be flagged.
        try """
        import Foundation

        struct OtherTool {
            /// Example: ToolDefinition(name: "get_weather", ...) — a DocC
            /// mention that must not be treated as a live declaration.
            static let definition = ToolDefinition(name: "unrelated_tool", description: "d", parameters: .object([:]))
        }
        """.write(to: root.appendingPathComponent("OtherTool.swift"), atomically: true, encoding: .utf8)

        let declarations = try Self.scan(sourcesRoot: tmp)
        let decoyNames = Set(declarations.filter { $0.file.hasSuffix("DecoyTools.swift") }.map(\.name))
        XCTAssertEqual(decoyNames, ["search_web", "get_movie_showtimes"], "expected both decoy names to be extracted; got \(decoyNames)")

        let collisions = declarations.filter { !$0.file.hasSuffix("DecoyTools.swift") && decoyNames.contains($0.name) }
        XCTAssertTrue(
            collisions.contains { $0.file.hasSuffix("RealWebSearchTool.swift") && $0.name == "search_web" },
            "The colliding search_web declaration must be flagged; got \(collisions)"
        )
        XCTAssertFalse(
            declarations.contains { $0.name == "get_weather" },
            "A ToolDefinition mention inside a doc comment must NOT be treated as a live declaration"
        )
        XCTAssertFalse(
            collisions.contains { $0.name == "unrelated_tool" },
            "A non-colliding shipped tool name must NOT be flagged"
        )
    }

    /// An allowlisted fingerprint (`file:name`) must exempt exactly the
    /// collision it names, mirroring `SilentCatchAuditTest`'s allowlist
    /// contract.
    func test_sabotage_allowlistExemptsNamedCollisionOnly() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "tool-name-collision-allowlist-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation

        enum DecoyTools {
            private static func def(_ name: String) -> Int { 0 }
            private static let pool = [
                def("get_weather"),
            ]
        }
        """.write(to: root.appendingPathComponent("DecoyTools.swift"), atomically: true, encoding: .utf8)

        try """
        import Foundation

        enum FixtureToolset {
            static let definition = ToolDefinition(name: "get_weather", description: "d", parameters: .object([:]))
        }
        """.write(to: root.appendingPathComponent("FixtureToolset.swift"), atomically: true, encoding: .utf8)

        let declarations = try Self.scan(sourcesRoot: tmp)
        let decoyNames = Set(declarations.filter { $0.file.hasSuffix("DecoyTools.swift") }.map(\.name))
        let unexempted = declarations.filter { !$0.file.hasSuffix("DecoyTools.swift") && decoyNames.contains($0.name) }
        XCTAssertFalse(unexempted.isEmpty, "expected the planted collision to be detected before allowlisting")

        let fingerprint = "ManifoldSomeModule/FixtureToolset.swift:get_weather"
        let allowlist: Set<String> = [fingerprint]
        let exempted = unexempted.filter { !allowlist.contains("\($0.file):\($0.name)") }
        XCTAssertTrue(exempted.isEmpty, "an allowlisted fingerprint must exempt the matching collision")
    }

    // MARK: - Detection

    struct ToolNameDeclaration: Equatable {
        let name: String
        let file: String
        let line: Int
    }

    static func scan(sourcesRoot: URL) throws -> [ToolNameDeclaration] {
        var declarations: [ToolNameDeclaration] = []
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesRoot)

        for fileURL in swiftFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            for (index, rawLine) in lines.enumerated() {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !Self.lineIsComment(trimmed) else { continue }

                // Shape 1a: same-line `ToolDefinition(name: "X"`.
                if let name = Self.firstCaptureGroup(pattern: #"ToolDefinition\(\s*name:\s*"([^"]+)""#, in: trimmed) {
                    declarations.append(ToolNameDeclaration(name: name, file: relativePath, line: index + 1))
                    continue
                }

                // Shape 1b: `ToolDefinition(` opener with `name: "X"` on a
                // following non-blank line (the common multi-line form).
                if trimmed.hasSuffix("ToolDefinition(") {
                    var peek = index + 1
                    while peek < lines.count {
                        let next = lines[peek].trimmingCharacters(in: .whitespaces)
                        if next.isEmpty { peek += 1; continue }
                        if !Self.lineIsComment(next),
                           let name = Self.firstCaptureGroup(pattern: #"^name:\s*"([^"]+)""#, in: next) {
                            declarations.append(ToolNameDeclaration(name: name, file: relativePath, line: peek + 1))
                        }
                        break
                    }
                    continue
                }

                // Shape 2: DecoyTools' own `def("X"` pool-entry helper.
                if let name = Self.firstCaptureGroup(pattern: #"\bdef\(\s*"([^"]+)""#, in: trimmed) {
                    declarations.append(ToolNameDeclaration(name: name, file: relativePath, line: index + 1))
                }
            }
        }

        return declarations
    }

    private static func lineIsComment(_ line: String) -> Bool {
        line.hasPrefix("//") || line.hasPrefix("*")
    }

    private static func firstCaptureGroup(pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[captureRange])
    }

    // MARK: - Allowlist loading

    /// Reads `tool_name_collision_allowlist.txt` from beside this source
    /// file. See `SilentCatchAuditTest.loadAllowlist(filePath:)` for the
    /// identical parsing rules (blank/`#`-comment lines skipped, trailing
    /// whitespace and CR trimmed).
    static func loadAllowlist(filePath: StaticString = #filePath) throws -> Set<String> {
        let url = allowlistURL(filePath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: Set<String> = []
        for rawLine in content.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            let leading = line.drop(while: { $0 == " " || $0 == "\t" })
            if leading.isEmpty { continue }
            if leading.first == "#" { continue }
            entries.insert(line)
        }
        return entries
    }

    private static func allowlistURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("tool_name_collision_allowlist.txt")
    }

    // MARK: - Helpers

    /// See `SilentCatchAuditTest`'s identical helper for why walking upward
    /// from `#filePath` is used to locate `Sources/`.
    private static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ToolNameCollisionAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
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

    /// See `SilentCatchAuditTest`'s identical helper for why `realpath()` is
    /// needed here (APFS firmlink `/var` → `/private/var`).
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
