import XCTest

/// Tripwire for `AGENTS.md` (the consumer-facing AI-coding-assistant guide
/// shipped at the repo root, alongside `CLAUDE.md` for contributors).
///
/// AGENTS.md exists so AI assistants helping someone *use* BaseChatKit have
/// a short, recipe-shaped surface that points at the right APIs. If the
/// file falls out of sync — references a method we deleted, drops a section,
/// goes missing entirely — assistants regenerate hallucinations the doc was
/// chartered to prevent. This test fails when that happens.
///
/// The checks are deliberately textual rather than structural: AGENTS.md is
/// markdown that sometimes wraps API names in inline code, sometimes in a
/// table cell, sometimes in prose. Greppy substring tests survive layout
/// edits; an HTML/markdown parser would couple us to formatting.
final class AgentsMdAuditTest: XCTestCase {

    /// Resolve `<repo-root>/AGENTS.md` from the test source location. Mirrors
    /// the pattern in `SilentCatchAuditTest` so this test works under both
    /// `swift test` and `xcodebuild test` without bundling the resource into
    /// the test target.
    private static func locateAgentsMd() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        // Tests/BaseChatInferenceTests/AgentsMdAuditTest.swift → repo root is 3 up.
        let repoRoot = here
            .deletingLastPathComponent()  // Tests/BaseChatInferenceTests/
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
    /// name `BaseChatBootstrap` so assistants don't reach for the legacy
    /// `configure(persistence:)` shape.
    func testReferencesBaseChatBootstrap() throws {
        let body = try Self.loadAgentsMd()
        XCTAssertTrue(
            body.contains("BaseChatBootstrap"),
            "AGENTS.md must reference `BaseChatBootstrap` as the canonical bootstrap entry point."
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
        // Match `vm.send(`, `viewModel.send(`, or `chatViewModel.send(` —
        // any "<identifier>.send(" that is not "<identifier>.sendMessage(".
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
                XCTFail("AGENTS.md line \(idx + 1) instructs consumers to call deleted method `\(matchedText)`: \(line)")
            }
        }
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
