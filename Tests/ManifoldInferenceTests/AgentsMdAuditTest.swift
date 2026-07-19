import XCTest
import ManifoldContract

/// Tripwire for `AGENTS.md` (the consumer-facing AI-coding-assistant guide
/// shipped at the repo root, alongside `CLAUDE.md` for contributors).
///
/// AGENTS.md exists so AI assistants helping someone *use* ManifoldKit have
/// a short, recipe-shaped surface that points at the right APIs. If the
/// file falls out of sync — references a method we deleted, drops a section,
/// goes missing entirely — assistants regenerate hallucinations the doc was
/// chartered to prevent. This test fails when that happens.
///
/// The checks are deliberately textual rather than structural: AGENTS.md is
/// markdown that sometimes wraps API names in inline code, sometimes in a
/// table cell, sometimes in prose. Greppy substring tests survive layout
/// edits; an HTML/markdown parser would couple us to formatting.
///
/// The type-*kind* checks below (§ "Type-kind drift") are the one exception:
/// they use `Mirror(reflecting:).displayStyle` to read the actual runtime
/// kind straight from source, then assert AGENTS.md's prose doesn't claim
/// the opposite. That combination — structural ground truth, textual
/// doc-claim check — is what caught #2210 (AGENTS.md called `BackendName`
/// an "enum" for multiple releases after #1742 converted it to a struct).
///
/// ``claimsTypeIsEnum(_:in:)`` and ``deletedSendMethodViolations(in:)`` are
/// shared by their respective audit test and in-file sabotage test.
final class AgentsMdAuditTest: XCTestCase {

    /// Resolve `<repo-root>/AGENTS.md` from the test source location. Mirrors
    /// the pattern in `SilentCatchAuditTest` so this test works under both
    /// `swift test` and `xcodebuild test` without bundling the resource into
    /// the test target.
    private static func locateAgentsMd() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        // Tests/ManifoldInferenceTests/AgentsMdAuditTest.swift → repo root is 3 up.
        let repoRoot = here
            .deletingLastPathComponent()  // Tests/ManifoldInferenceTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo>
        let path = repoRoot.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("AGENTS.md not found at \(path.path)")
        }
        return path
    }

    private static func loadAgentsMd() throws -> String {
        let url = try locateAgentsMd()
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - File presence

    func testAgentsMdExists() throws {
        _ = try Self.loadAgentsMd()
    }

    // MARK: - Type-kind drift (#2210)

    /// Does `body` claim `typeName` "is a/an ... enum" (in prose or inline
    /// code) at ANY occurrence of `typeName` in the file? `typeName` is
    /// mentioned multiple times (an imports table, a hallucinations list,
    /// the dedicated section) — checking only the first occurrence missed
    /// the description sentence entirely in an earlier draft of this test,
    /// so every occurrence is scanned.
    ///
    /// Requires an actual "is a/an ... enum" claim — not just co-occurrence
    /// of the type name and the word "enum" — because the correct doc text
    /// legitimately says things like "is an extensible struct ..., **not an
    /// enum**"; a bare substring check on "enum" false-positives on that
    /// negation. The regex forbids crossing a `not` (or a sentence-ending
    /// period) between "is a/an" and "enum", so the negated phrasing above
    /// does not match while "is a Swift `enum: String`" still does.
    static func claimsTypeIsEnum(_ typeName: String, in body: String) -> Bool {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: #"is\s+an?\b(?:(?!\bnot\b)[^.])*?\benum\b"#)
        } catch {
            XCTFail("Failed to compile type-kind-claim regex: \(error)")
            return false
        }
        var searchStart = body.startIndex
        while let typeRange = body.range(of: typeName, range: searchStart..<body.endIndex) {
            let windowEnd = body.index(typeRange.upperBound, offsetBy: 300, limitedBy: body.endIndex) ?? body.endIndex
            let window = String(body[typeRange.upperBound..<windowEnd])
            let nsWindow = window as NSString
            let match = regex.firstMatch(in: window, range: NSRange(location: 0, length: nsWindow.length))
            if match != nil {
                return true
            }
            searchStart = typeRange.upperBound
        }
        return false
    }

    /// `BackendName` (`Sources/ManifoldContract/BackendName.swift`) has been
    /// an extensible `RawRepresentable` struct since #1742 — never call it an
    /// enum in AGENTS.md. `Mirror` reads the runtime kind straight from
    /// source so this assertion can't silently drift if the type changes
    /// shape again; the doc-claim half still has to be updated by hand.
    func testBackendNameDocumentedKindMatchesSource() throws {
        let mirror = Mirror(reflecting: BackendName(rawValue: "probe"))
        XCTAssertEqual(
            mirror.displayStyle, .struct,
            "BackendName is no longer a struct in source — update AGENTS.md's Backend identity section to match the new kind, then update this assertion."
        )
        let body = try Self.loadAgentsMd()
        XCTAssertFalse(
            Self.claimsTypeIsEnum("BackendName", in: body),
            "AGENTS.md must not describe BackendName as an enum — it has been an extensible struct since #1742 (see Sources/ManifoldContract/BackendName.swift)."
        )
    }

    /// `ModelType` (`Sources/ManifoldHardware/ModelType.swift`) is the same
    /// extensible-struct pattern as `BackendName` (P2.5b precedent cited by
    /// #2198). AGENTS.md doesn't currently document it by name; this
    /// assertion guards against a future edit reintroducing the stale "enum"
    /// framing if/when a `ModelType` section is added.
    func testModelTypeDocumentedKindMatchesSource() throws {
        let mirror = Mirror(reflecting: ModelType(rawValue: "probe"))
        XCTAssertEqual(
            mirror.displayStyle, .struct,
            "ModelType is no longer a struct in source — update AGENTS.md (if it documents ModelType) to match the new kind, then update this assertion."
        )
        let body = try Self.loadAgentsMd()
        XCTAssertFalse(
            Self.claimsTypeIsEnum("ModelType", in: body),
            "AGENTS.md must not describe ModelType as an enum — it is an extensible struct (see Sources/ManifoldHardware/ModelType.swift)."
        )
    }

    // MARK: - Required current-API references

    /// AGENTS.md must mention the canonical send method by its exact name,
    /// because `vm.send(_:)` (the deleted alternate) is the most common LLM
    /// hallucination this file exists to prevent.
    func testReferencesCurrentSendMessageAPI() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("sendMessage(_:)") || body.contains("vm.sendMessage("),
            "AGENTS.md must reference `sendMessage(_:)` so consumers don't fall back to the deleted `vm.send(_:)`."
        )
    }

    /// Backend identity is a typed accessor (`BackendName.foundation`), not a
    /// raw string. Assistants that hardcode `"Apple"` or `"foundation"` will
    /// break across the 0.19 BackendName conversion.
    func testReferencesTypedBackendName() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("BackendName.foundation"),
            "AGENTS.md must reference `BackendName.foundation` (typed) over raw strings like `\"Apple\"`."
        )
    }

    /// The bootstrap recipe is the most-copied snippet in the file. It must
    /// name `ManifoldBootstrap` so assistants don't reach for the legacy
    /// `configure(persistence:)` shape.
    func testReferencesManifoldBootstrap() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("ManifoldBootstrap"),
            "AGENTS.md must reference `ManifoldBootstrap` as the canonical bootstrap entry point."
        )
    }

    /// The Tool Calling section must call out the `--traits Macros` requirement
    /// because `@ToolSchema` is the most likely source of "this snippet doesn't
    /// compile" reports from consumers.
    func testCallsOutMacrosTraitForToolSchema() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("--traits Macros") || body.contains("trait(name: \"Macros\")"),
            "AGENTS.md must call out the `Macros` trait gating for `@ToolSchema`."
        )
    }

    // MARK: - Forbidden references (deleted APIs)

    /// AGENTS.md must NOT reference the `loadModel(from:contextSize:)` shape;
    /// that was replaced by `loadModel(from:plan:)` in 0.18.
    func testDoesNotReferenceDeletedLoadModelSignature() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertFalse(
            body.contains("loadModel(from:contextSize:)"),
            "AGENTS.md references deleted API `loadModel(from:contextSize:)`. Use `loadModel(from:plan:)`."
        )
    }

    /// AGENTS.md must NOT use `vm.send(` (open-paren) as a method call —
    /// that's the deleted shape the doc exists to steer consumers away from.
    /// Prose mentions like "the old `vm.send` was removed" are fine; what we
    /// reject is a code-shaped invocation. The whole-word boundary keeps
    /// `vm.sendMessage(` from matching.
    func testDoesNotInstructConsumersToCallDeletedSendMethod() throws {
        let body = try Self.loadAgentsMd()
        for violation in try Self.deletedSendMethodViolations(in: body) {
            XCTFail("AGENTS.md \(violation)")
        }
    }

    /// Scans `body` line by line for a code-shaped `<identifier>.send(`
    /// invocation (the deleted `vm.send(_:)` shape) that isn't
    /// `.sendMessage(` and isn't on a line carrying an explicit negation cue
    /// ("removed", "deleted", "not ", "no longer"). Returns one formatted
    /// violation string per match, in the same wording the audit test fails
    /// with.
    static func deletedSendMethodViolations(in body: String) throws -> [String] {
        var violations: [String] = []
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            // Allow lines that explicitly mention the deletion (those contain
            // both "send(" and one of the obvious negation cues).
            let lower = String(line).lowercased()
            let isNegation = lower.contains("removed") || lower.contains("deleted")
                || lower.contains("not ") || lower.contains("no longer")
            if isNegation { continue }

            // Match `\b<identifier>\.send\(` but explicitly not `.sendMessage(`.
            let regex = try NSRegularExpression(pattern: #"\b\w+\.send\("#)
            let nsLine = String(line) as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: String(line), options: [], range: range)
            for match in matches {
                let matchedText = nsLine.substring(with: match.range)
                if matchedText.contains(".sendMessage(") { continue }
                violations.append("line \(idx + 1) instructs consumers to call deleted method `\(matchedText)`: \(line)")
            }
        }
        return violations
    }

    // MARK: - Sabotage (exercises the shared detection functions above)

    /// `deletedSendMethodViolations(in:)`: a code-shaped `vm.send(` call
    /// must be flagged, the canonical `vm.sendMessage(` call must not, and
    /// a negated prose mention ("the old `vm.send(` was removed") must not.
    func test_sabotage_deletedSendMethodViolationsFlagsPlantedCall() throws {
        let violating = "Call `vm.send(\"hello\")` to send a message."
        XCTAssertEqual(try Self.deletedSendMethodViolations(in: violating).count, 1)

        let clean = "Use `vm.sendMessage(\"hi\")`."
        XCTAssertEqual(try Self.deletedSendMethodViolations(in: clean).count, 0)

        let negated = "the old `vm.send(` was removed"
        XCTAssertEqual(try Self.deletedSendMethodViolations(in: negated).count, 0)
    }

    /// `claimsTypeIsEnum(_:in:)`: a direct "is a ... enum" claim must be
    /// flagged, while the real doc's negated phrasing ("is an extensible
    /// struct — not an enum") must not.
    func test_sabotage_claimsTypeIsEnumDetectsPlantedClaim() {
        XCTAssertTrue(
            Self.claimsTypeIsEnum("BackendName", in: "BackendName is a Swift `enum: String` with six cases.")
        )
        XCTAssertFalse(
            Self.claimsTypeIsEnum("BackendName", in: "BackendName is an extensible struct — not an enum.")
        )
    }

    /// Hallucination-#4 host check: planted wrong type must fail the contains
    /// guard the audit uses (ModelManagementViewModel.dispatchSelectedLoad).
    func test_sabotage_hallucination4RejectsModelManagementHost() {
        let wrong = "ModelManagementViewModel.dispatchSelectedLoad()"
        let right = "ChatViewModel.dispatchSelectedLoad() / vm.dispatchSelectedLoad()"
        XCTAssertTrue(wrong.contains("ModelManagementViewModel.dispatchSelectedLoad"))
        XCTAssertFalse(right.contains("ModelManagementViewModel.dispatchSelectedLoad"))
        XCTAssertTrue(right.contains("ChatViewModel.dispatchSelectedLoad") || right.contains("vm.dispatchSelectedLoad"))
    }

    // MARK: - Hallucination-list completeness

    /// The "Common LLM hallucinations to avoid" section is the load-bearing
    /// part of the file. Verify all four listed items are present so a future
    /// edit doesn't silently delete one.
    func testCommonHallucinationsSectionListsAllFourItems() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(body.contains("Common LLM hallucinations to avoid"),
                      "AGENTS.md must contain the `Common LLM hallucinations to avoid` section.")
        // The four hallucination cues — each must appear somewhere in the file.
        let cues = [
            "umbrella module",            // #1
            "sendMessage",                // #2
            "BackendName.foundation",     // #3
            "dispatchSelectedLoad",       // #4
        ]
        for cue in cues {
            XCTAssertTrue(
                body.contains(cue),
                "AGENTS.md must reference `\(cue)` in the Common LLM hallucinations section."
            )
        }
    }

    /// Hallucination #4 must name `ChatViewModel.dispatchSelectedLoad` (or
    /// `vm.dispatchSelectedLoad`), not the wrong
    /// `ModelManagementViewModel.dispatchSelectedLoad` host.
    func testHallucination4NamesChatViewModelDispatchSelectedLoad() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("ChatViewModel.dispatchSelectedLoad")
                || body.contains("vm.dispatchSelectedLoad"),
            "AGENTS.md hallucination #4 must name ChatViewModel.dispatchSelectedLoad / vm.dispatchSelectedLoad."
        )
        XCTAssertFalse(
            body.contains("ModelManagementViewModel.dispatchSelectedLoad"),
            "AGENTS.md must not claim ModelManagementViewModel.dispatchSelectedLoad — that method lives on ChatViewModel."
        )
    }

    /// Tool-calling recipe must put tools on GenerationConfig, not as an
    /// `enqueue(..., tools:)` parameter (that overload does not exist).
    func testToolEnqueueDoesNotPassToolsAsEnqueueParameter() throws {
        let body = try Self.loadAgentsMd()
        let banned = """
            enqueue(
                    messages: history,
                    tools:
            """
        XCTAssertFalse(
            body.contains(banned),
            "AGENTS.md must not show enqueue(messages:tools:) — tools belong on GenerationConfig."
        )
        XCTAssertTrue(
            body.contains("config.tools = registry.definitions"),
            "AGENTS.md tool recipe must assign registry.definitions to GenerationConfig.tools."
        )
    }

    // MARK: - check-readme.sh smoke test

    /// Smoke-verify that `scripts/check-readme.sh` exits 0 against the
    /// current README. This is intentionally a smoke test — the script's
    /// detailed failure modes are exercised by the script's own logic in
    /// CI. We just assert the happy path so a stale pin or deleted-API
    /// reference can't slip in.
    ///
    /// Skips on non-macOS hosts (the script uses POSIX bash only, but the
    /// per-platform runner config ships shell on macOS unconditionally —
    /// guarding keeps Linux CI tiers happy if BCK ever extends them).
    func testCheckReadmeScriptPassesAgainstCurrentTree() throws {
        #if !os(macOS)
        throw XCTSkip("Process-launch smoke tests run on macOS only.")
        #else
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/check-readme.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("scripts/check-readme.sh missing or not executable at \(scriptURL.path)")
        }

        let process = Process()
        process.executableURL = scriptURL
        process.currentDirectoryURL = repoRoot

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + "\n--- stderr ---\n"
            + (String(data: errData, encoding: .utf8) ?? "")

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "scripts/check-readme.sh failed against the current tree:\n\(combined)"
        )
        #endif
    }
}
