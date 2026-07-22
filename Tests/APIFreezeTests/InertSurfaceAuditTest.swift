import XCTest
import Foundation

/// Inert-surface tripwire (issue #2128).
///
/// ## What this catches
///
/// The #2128 campaign's root cause: public symbols with **zero production
/// references** shipped silently — a `public` type or function nothing in
/// `Sources/` ever used, which lies to every future reader about being part of
/// the live API. This audit makes that class of drift fail a test.
///
/// For every public **type** (`Struct`/`Class`/`Enum`/`Protocol`) and every
/// **top-level public function** named in the checked-in api-surface baselines
/// (`Tests/APIFreezeTests/api-surface-baseline/*.txt`), it greps `Sources/` for
/// a reference **outside the symbol's own declaring file**. A symbol with no
/// such reference must be listed, with a mandatory `# reason:` annotation, in
/// `Tests/APIFreezeTests/inert-surface-allowlist.txt` — otherwise the test
/// fails. Every allowlist entry is a documented decision (a seam with no reader
/// yet, an experimental surface, a companion-consumed field), never a silent
/// mute.
///
/// ## Scope choices (documented, deliberate)
///
/// - **Types + top-level funcs only, not members.** Member-level reference
///   checking is far too noisy — generic member names (`begin`, `current`,
///   `capabilities`, `generate`) collide across unrelated types and produce
///   false "live" and false "inert" readings alike. Types and top-level funcs
///   have distinctive names, so a bare-identifier reference scan is reliable
///   for them. (This is why the #2351 demotion screen also hand-adjudicated
///   member-name hits separately.)
///
/// - **Nested types are skipped.** A baseline entry like
///   `ManifoldSchemaV11.ToolCallConformanceRecord` (owner contains a `.`) is
///   treated as a member of its parent; only top-level type names and
///   `(top-level).`-prefixed entries are checked.
///
/// - **References are counted in `Sources/` only, never `Tests/`.** A public
///   symbol that only tests touch IS inert — that's the exact shape this audit
///   exists to catch. Test-only usage does not rescue a symbol.
///
/// - **Three test-support modules are excluded wholesale**:
///   `ManifoldTestSupport`, `ManifoldPersistenceTestSupport`, and
///   `ManifoldBackendTestKit`. They are published `.library` products consumed
///   **by the companion packages' test targets** (manifold-mlx / manifold-llama),
///   which this repo cannot see, so every symbol in them is a guaranteed false
///   positive here. Their sources are still scanned as *reference* sources (a
///   core type used only by a mock still reads as live).
///
/// ## Residual false-positive classes (why the allowlist is not tiny)
///
/// "No reference in this repo's `Sources/`" deliberately does NOT prove dead —
/// a library's public surface is mostly consumed *downstream*, which this repo
/// cannot see. The allowlist enumerates every such symbol with a `# reason:`,
/// and its real value is the **delta**: a *new* inert symbol fails until it is
/// either removed or justified here. The standing residual classes are:
///
/// - **host-facing** — a public entry point (View, error, config, result type)
///   a downstream app consumes but nothing in this repo does. The largest class.
/// - **companion-consumed** — referenced only by manifold-mlx / manifold-llama /
///   manifold-eval: `BackendCapabilities.toolDialect` (set by `MLXBackend`/
///   `LlamaBackend`), the local-inference seams (`LocalToolCallShape`, the
///   `Llama*SamplerOptions`), the opt-in protocols (`CancellableModelLoading`, …).
/// - **experimental** — surface in an experimental module (AppEval, AppIntents,
///   MCPHost) whose first real adopter has not landed.
/// - **dev-tool** — surface exercised by an executable/fuzz harness, not a
///   `.library` consumer (`ManifoldFuzz`, `ManifoldTools`).
/// - **documented seam** — a public seam whose intended in-repo reader is not
///   built yet (`PromptAssembler`, `EmbeddingCapabilities`), documented as such.
///
/// A documented-but-uncalled seam is intentionally still flagged: the doc
/// comment is a claim, `# reason:` in this file is the *decision* to keep it.
///
/// ## Reference matching
///
/// Reference and declaration detection are word-bounded on Swift identifier
/// characters (`[A-Za-z0-9_]`), so `Foo` never matches inside `FooBar` or
/// `myFoo`. Pure comment lines (`//`, `///`, block-comment continuations) are
/// skipped in both passes, so a doc-comment mention of a symbol does not count
/// as a live reference. Block-comment handling is a line-prefix approximation
/// (`*` / `/*`), adequate for this codebase's `///`-dominant doc style.
///
/// The detection lives in ``inertSymbols(symbols:index:allowlist:)`` so the
/// in-file `test_sabotage_…` exercises the exact function the audit runs.
final class InertSurfaceAuditTest: XCTestCase {

    /// Products excluded from the symbol set (still scanned for references).
    /// See the type doc — these are consumed wholesale by companion test
    /// targets this repo cannot see.
    static let excludedModules: Set<String> = [
        "ManifoldTestSupport",
        "ManifoldPersistenceTestSupport",
        "ManifoldBackendTestKit",
    ]

    private static let typeKinds: Set<String> = ["Struct", "Class", "Enum", "Protocol"]
    private static let declKeywords: Set<String> = [
        "struct", "class", "enum", "protocol", "actor", "typealias", "func",
    ]

    // MARK: - The audit

    func test_noUnannotatedInertPublicSurface() throws {
        let root = Self.repoRoot()
        let baselineDir = root.appendingPathComponent("Tests/APIFreezeTests/api-surface-baseline")
        let sourcesDir = root.appendingPathComponent("Sources")
        let allowlistURL = root.appendingPathComponent("Tests/APIFreezeTests/inert-surface-allowlist.txt")

        let (symbols, provenance) = try Self.symbolsToCheck(baselineDir: baselineDir)
        XCTAssertFalse(symbols.isEmpty, "Parsed zero symbols from the baselines — path or parser is wrong.")

        let index = try Self.buildSourceIndex(sourcesDir: sourcesDir)
        let allowlist = try Self.loadAllowlist(allowlistURL)

        // Everything inert regardless of the allowlist — used both to compute
        // the unannotated set and to spot stale allowlist entries.
        let inertAll = Set(Self.inertSymbols(symbols: symbols, index: index, allowlist: []))
        let unannotated = Self.inertSymbols(symbols: symbols, index: index, allowlist: allowlist)

        if !unannotated.isEmpty {
            let listing = unannotated.map { sym -> String in
                let mods = provenance[sym].map { $0.sorted().joined(separator: ", ") } ?? "?"
                return "  - \(sym)  (\(mods))"
            }.joined(separator: "\n")
            XCTFail("""
                The following public symbols have zero references in Sources/ outside
                their own declaring file — they are inert public surface (#2128):

                \(listing)

                Each must be either REMOVED, or added to
                Tests/APIFreezeTests/inert-surface-allowlist.txt with a `# reason:`
                annotation (documented seam / experimental / companion-consumed /
                host-facing query surface). An allowlist entry is a decision, not a
                mute — say why the symbol legitimately has no in-repo reader.
                """)
        }

        // Keep the allowlist honest: an entry that no longer names an inert
        // symbol (it gained a reference, or was deleted) is stale and must be
        // pruned so the file stays a live ledger.
        let stale = allowlist.subtracting(inertAll).sorted()
        if !stale.isEmpty {
            XCTFail("""
                These inert-surface-allowlist.txt entries are stale — the symbol is no
                longer inert (it gained a Sources/ reference) or no longer exists:

                \(stale.map { "  - \($0)" }.joined(separator: "\n"))

                Remove them from Tests/APIFreezeTests/inert-surface-allowlist.txt.
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `inertSymbols(...)` the audit runs)

    /// Plants a declared-but-unreferenced public type in a temp Sources tree +
    /// synthetic baseline and asserts the REAL detection flags it — and that a
    /// referenced sibling is NOT flagged, and that an allowlist entry silences
    /// the planted one.
    func test_sabotage_flagsPlantedInertSymbolAndRespectsReferencesAndAllowlist() throws {
        let tmp = try Self.makeSabotageTempDirectory(name: "inert-surface-sabotage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Synthetic baseline: two top-level types + one member (member must be ignored).
        let baselineDir = tmp.appendingPathComponent("baseline", isDirectory: true)
        try FileManager.default.createDirectory(at: baselineDir, withIntermediateDirectories: true)
        try """
        PlantedInertSymbol Struct
        UsedSymbol Struct
        UsedSymbol.value Var
        """.write(to: baselineDir.appendingPathComponent("TestModule.txt"), atomically: true, encoding: .utf8)

        // Synthetic Sources: PlantedInertSymbol declared, referenced nowhere;
        // UsedSymbol declared AND referenced from a second file.
        let sources = tmp.appendingPathComponent("Sources", isDirectory: true)
        let moduleDir = sources.appendingPathComponent("TestModule", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        try "public struct PlantedInertSymbol { public init() {} }"
            .write(to: moduleDir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        try "public struct UsedSymbol { public let value = 1; public init() {} }"
            .write(to: moduleDir.appendingPathComponent("Used.swift"), atomically: true, encoding: .utf8)
        try """
        func consume() {
            // PlantedInertSymbol appears here only in a comment — must NOT count.
            _ = UsedSymbol()
        }
        """.write(to: moduleDir.appendingPathComponent("Consumer.swift"), atomically: true, encoding: .utf8)

        let (symbols, _) = try Self.symbolsToCheck(baselineDir: baselineDir)
        XCTAssertEqual(Set(symbols), ["PlantedInertSymbol", "UsedSymbol"],
                       "Members must be dropped; both top-level types kept")

        let index = try Self.buildSourceIndex(sourcesDir: sources)

        let flaggedNoAllowlist = Self.inertSymbols(symbols: symbols, index: index, allowlist: [])
        XCTAssertEqual(flaggedNoAllowlist, ["PlantedInertSymbol"],
                       "Only the unreferenced type is inert; UsedSymbol is referenced in Consumer.swift, "
                       + "and PlantedInertSymbol's comment-only mention there must not rescue it")

        let flaggedWithAllowlist = Self.inertSymbols(symbols: symbols, index: index, allowlist: ["PlantedInertSymbol"])
        XCTAssertTrue(flaggedWithAllowlist.isEmpty,
                      "An allowlisted symbol must be suppressed")
    }

    // MARK: - Baseline parsing

    /// Returns the sorted set of top-level type + top-level func names to check,
    /// plus a symbol→modules provenance map for the failure message. Excludes
    /// the test-support modules and skips members / nested types.
    static func symbolsToCheck(baselineDir: URL) throws -> (symbols: [String], provenance: [String: Set<String>]) {
        let files = try FileManager.default.contentsOfDirectory(at: baselineDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .filter { !excludedModules.contains($0.deletingPathExtension().lastPathComponent) }

        var provenance: [String: Set<String>] = [:]
        for fileURL in files {
            let module = fileURL.deletingPathExtension().lastPathComponent
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine)
                // Skip the isolation/Sendable-signal lines.
                if line.contains(" conformances: ") || line.contains(" attrs: ") { continue }
                guard let lastSpace = line.range(of: " ", options: .backwards) else { continue }
                let kind = String(line[lastSpace.upperBound...])
                var owner = String(line[..<lastSpace.lowerBound])
                if owner.hasPrefix("(top-level).") {
                    owner = String(owner.dropFirst("(top-level).".count))
                }

                if typeKinds.contains(kind) {
                    guard !owner.contains(".") else { continue }   // nested type → skip
                    provenance[owner, default: []].insert(module)
                } else if kind == "Func" {
                    guard let paren = owner.firstIndex(of: "(") else { continue }
                    let name = String(owner[..<paren])
                    guard !name.contains("."), !name.isEmpty else { continue } // member func → skip
                    provenance[name, default: []].insert(module)
                }
            }
        }
        return (provenance.keys.sorted(), provenance)
    }

    // MARK: - Source index

    struct SourceIndex {
        /// identifier token → set of file paths in which it appears (code lines only).
        var occurrences: [String: Set<String>] = [:]
        /// declared name → set of file paths declaring it (`struct`/`func`/… <name>).
        var declarations: [String: Set<String>] = [:]
    }

    /// Builds the reference index from `.swift` sources under `sourcesDir`.
    ///
    /// Only **code** counts: pure comment lines (`//`, `///`, block-comment
    /// continuations) are skipped for both occurrences and declarations. This
    /// is deliberate — a `///`-linked symbol nothing *calls* is still inert
    /// (the superseded-but-documented `PromptAssembler` shape #2128 wants
    /// flagged), and DocC/markdown mentions are documentation, not production
    /// references. Every non-comment identifier token becomes an *occurrence*;
    /// an identifier immediately following a decl keyword is a *declaration*.
    static func buildSourceIndex(sourcesDir: URL) throws -> SourceIndex {
        var index = SourceIndex()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return index
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for rawLine in contents.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let tokens = Self.identifiers(in: rawLine)
                for token in tokens { index.occurrences[token, default: []].insert(path) }
                for i in tokens.indices.dropLast() where declKeywords.contains(tokens[i]) {
                    index.declarations[tokens[i + 1], default: []].insert(path)
                }
            }
        }
        return index
    }

    /// Tokenises a line into Swift identifiers (`[A-Za-z_][A-Za-z0-9_]*`),
    /// preserving order (declaration detection needs keyword→name adjacency).
    static func identifiers(in line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in line.unicodeScalars {
            let c = Character(scalar)
            let isIdentChar = c == "_" || c.isLetter || c.isNumber
            if isIdentChar {
                // A leading digit can't start an identifier; if `current` is empty
                // and c is a digit, it's part of a number literal — skip starting.
                if current.isEmpty && c.isNumber { continue }
                current.append(c)
            } else {
                if !current.isEmpty { out.append(current); current = "" }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Detection

    /// The audit's core: a symbol is inert when it is declared somewhere in
    /// `Sources/` but every file that mentions it is also a file that declares
    /// it (i.e. nothing outside its declaring file(s) references it) — and it is
    /// not on the allowlist. Symbols with no declaration in `Sources/` at all
    /// are skipped (a stale baseline entry or a re-export of an external type is
    /// not this audit's concern).
    static func inertSymbols(symbols: [String], index: SourceIndex, allowlist: Set<String>) -> [String] {
        var inert: [String] = []
        for symbol in symbols {
            guard let declFiles = index.declarations[symbol], !declFiles.isEmpty else { continue }
            let occ = index.occurrences[symbol] ?? []
            let references = occ.subtracting(declFiles)
            if references.isEmpty, !allowlist.contains(symbol) {
                inert.append(symbol)
            }
        }
        return inert.sorted()
    }

    // MARK: - Allowlist

    /// Loads the allowlist: one symbol per non-comment line, each requiring a
    /// `# reason:` annotation. Throws (fails the test) on any entry lacking one.
    static func loadAllowlist(_ url: URL) throws -> Set<String> {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: Set<String> = []
        for (n, rawLine) in contents.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let hash = line.firstIndex(of: "#") else {
                throw NSError(domain: "InertSurfaceAudit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "inert-surface-allowlist.txt line \(n + 1) has no `# reason:` annotation: \"\(line)\". "
                        + "Every entry must document why the symbol has no in-repo reader.",
                ])
            }
            let symbol = line[..<hash].trimmingCharacters(in: .whitespaces)
            let comment = line[line.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { continue }
            guard comment.lowercased().hasPrefix("reason:") else {
                throw NSError(domain: "InertSurfaceAudit", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "inert-surface-allowlist.txt line \(n + 1) annotation must start with `reason:` — got \"# \(comment)\".",
                ])
            }
            out.insert(symbol)
        }
        return out
    }

    // MARK: - Filesystem discovery

    private static func repoRoot(filePath: StaticString = #filePath) -> URL {
        // Tests/APIFreezeTests/InertSurfaceAuditTest.swift → repo root is 3 up.
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()  // Tests/APIFreezeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo>
    }

    /// Fresh UUID-suffixed temp dir, fully resolved via `realpath()` so the
    /// enumerator's `/private/var/...` child paths string-match the root prefix
    /// (see `SessionConstructionAuditTest` for the `/var` firmlink rationale).
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
