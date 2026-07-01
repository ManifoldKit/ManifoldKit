import XCTest
import Foundation
import ManifoldInference

/// # ManifoldAuditSabotageSuite
///
/// Nightly-only. Verifies that every file-walking audit test catches
/// known violations — the "who watches the watchers" guard.
///
/// Run with:
///   SABOTAGE=1 swift test --filter ManifoldAuditSabotageSuiteTests --disable-default-traits
///
/// Without SABOTAGE=1, all tests skip immediately.
///
/// Each test:
/// 1. Creates a temp directory mimicking the relevant source layout.
/// 2. Writes a file that violates the constraint the audit enforces.
/// 3. Reimplements the audit's check logic inline (SwiftPM forbids
///    `@testable import` of test targets, so logic is inlined minimally).
/// 4. Asserts the violation is detected.
///
/// All tests PASS when `SABOTAGE=1` — they assert violations ARE caught.
final class AuditSabotageSuiteTests: XCTestCase {

    // MARK: - SABOTAGE guard

    /// Returns early with XCTSkip unless the caller has exported SABOTAGE=1.
    /// Avoids running expensive temp-dir creation in the normal CI lane.
    private func requireSabotageMode(file: StaticString = #file, line: UInt = #line) throws {
        guard ProcessInfo.processInfo.environment["SABOTAGE"] == "1" else {
            throw XCTSkip("Set SABOTAGE=1 to run sabotage suite")
        }
    }

    // MARK: - Temp directory helpers

    private func makeTemp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sabotage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func write(_ content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 1. SessionConstructionAuditTest sabotage

    /// `SessionConstructionAuditTest` forbids `URLSession(` outside the
    /// `URLSessionProvider.swift` allowlist. A new cloud file containing a
    /// direct `URLSession(configuration: .default)` must be caught.
    func test_sessionConstructionAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cloudDir = tmp.appendingPathComponent("ManifoldCloud", isDirectory: true)
        let offendingFile = cloudDir.appendingPathComponent("BadBackend.swift")
        try write("""
            import Foundation
            // This file deliberately constructs URLSession outside the seam.
            let session = URLSession(configuration: .default)
            """, to: offendingFile)

        // Inline the audit's detection logic.
        let swiftFiles = try FileManager.default.contentsOfDirectory(
            at: cloudDir, includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { $0.pathExtension == "swift" }

        let allowlisted: Set<String> = ["URLSessionProvider.swift"]
        var offenders: [(file: String, line: Int)] = []
        for fileURL in swiftFiles {
            let name = fileURL.lastPathComponent
            if allowlisted.contains(name) { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.contains("`URLSession(`") { continue }
                if line.contains("URLSession(") {
                    offenders.append((file: name, line: idx + 1))
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected SessionConstructionAuditTest to detect URLSession( in \(offendingFile.lastPathComponent), but found no offenders"
        )
    }

    // MARK: - 2. DNSRebindingCoverageAuditTest sabotage

    /// `DNSRebindingCoverageAuditTest` forbids `DNSRebindingGuard` references
    /// outside the allowlisted files. A new backend file referencing it
    /// directly must be caught.
    func test_dnsRebindingCoverageAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cloudDir = tmp.appendingPathComponent("ManifoldCloud", isDirectory: true)
        let offendingFile = cloudDir.appendingPathComponent("GeminiBackend.swift")
        try write("""
            import Foundation
            // Deliberately referencing DNSRebindingGuard outside the envelope.
            func check() { _ = DNSRebindingGuard() }
            """, to: offendingFile)

        let allowlisted: Set<String> = [
            "DNSRebindingGuard.swift",
            "SSECloudBackend.swift",
            "URLSessionProvider.swift",
            "OllamaBackend.swift",
            "OllamaModelListService.swift",
        ]

        let swiftFiles = try FileManager.default.contentsOfDirectory(
            at: cloudDir, includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { $0.pathExtension == "swift" }

        var offenders: [(file: String, line: Int)] = []
        for fileURL in swiftFiles {
            let rel = "ManifoldCloud/" + fileURL.lastPathComponent
            if allowlisted.contains(fileURL.lastPathComponent) { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.contains("DNSRebindingGuard") {
                    offenders.append((file: rel, line: idx + 1))
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected DNSRebindingCoverageAuditTest to detect violation, but found no offenders"
        )
    }

    // MARK: - 3. CloudSeamUsageAuditTest sabotage

    /// `CloudSeamUsageAuditTest` requires every `*Backend.swift` to reference
    /// `CloudHTTPProviderAdapter` (or be in the legacy allowlist). A new
    /// backend file that does neither must be caught.
    func test_cloudSeamUsageAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // write() creates parent dirs including cloudDir.
        // The file content must NOT mention the adapter — that's the violation.
        let cloudDir = tmp.appendingPathComponent("ManifoldCloud")
        let offendingFile = cloudDir.appendingPathComponent("GeminiBackend.swift")
        try write("""
            import Foundation
            // New backend — missing required adapter composition.
            final class GeminiBackend: NSObject {}
            """, to: offendingFile)

        let legacyAllowlist: Set<String> = []  // Phase 5: empty, all backends use adapter

        // Verify the file was written.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: offendingFile.path),
            "Precondition: offending file should have been created"
        )

        // Mirror the top-level-only enumeration used by CloudSeamUsageAuditTest.
        let allEntries = try FileManager.default.contentsOfDirectory(atPath: cloudDir.path)
        let swiftFileNames = allEntries.filter { $0.hasSuffix(".swift") }

        XCTAssertFalse(swiftFileNames.isEmpty, "Precondition: should find at least GeminiBackend.swift in cloudDir")

        var offenders: [String] = []
        for name in swiftFileNames {
            guard name.hasSuffix("Backend.swift") else { continue }
            if legacyAllowlist.contains(name) { continue }
            let fileURL = cloudDir.appendingPathComponent(name)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if !content.contains("CloudHTTPProviderAdapter") {
                offenders.append(name)
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected CloudSeamUsageAuditTest to detect GeminiBackend.swift missing adapter, but found no offenders"
        )
    }

    // MARK: - 4. DirectURLSessionConstructionAuditTest sabotage

    /// `DirectURLSessionConstructionAuditTest` forbids `URLSession(configuration:`
    /// throughout Sources/ (outside the seam and test-support). A production
    /// file that uses it directly must be caught.
    func test_directURLSessionConstructionAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Mimic a Sources/ManifoldRuntime/ file with a direct URLSession construction.
        let runtimeDir = tmp.appendingPathComponent("ManifoldRuntime", isDirectory: true)
        let offendingFile = runtimeDir.appendingPathComponent("BadNetworkService.swift")
        try write("""
            import Foundation
            // Unauthorised direct URLSession construction.
            let session = URLSession(configuration: .ephemeral)
            """, to: offendingFile)

        // Inline the detection logic from DirectURLSessionConstructionAuditTest.
        let allowlistedRelativePaths: Set<String> = [
            "ManifoldInference/Networking/URLSessionFactory.swift",
            "ManifoldCloudCore/URLSessionProvider.swift",
            "ManifoldMCP/MCPURLSessionFactory.swift",
        ]
        let allowlistedPrefixes: [String] = ["ManifoldTestSupport/"]

        func isAllowlisted(_ rel: String) -> Bool {
            if allowlistedRelativePaths.contains(rel) { return true }
            return allowlistedPrefixes.contains { rel.hasPrefix($0) }
        }

        func lineConstructsURLSession(_ line: String) -> Bool {
            if line.hasPrefix("//") || line.hasPrefix("///") { return false }
            return line.contains("URLSession(configuration:")
        }

        var offenders: [(file: String, line: Int)] = []
        if let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: tmp.path + "/", with: "")
                if isAllowlisted(rel) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if lineConstructsURLSession(trimmed) {
                        offenders.append((file: rel, line: idx + 1))
                    }
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected DirectURLSessionConstructionAuditTest to detect violation, but found no offenders"
        )
    }

    // MARK: - 5. FixtureRedactionAuditTest sabotage

    /// `FixtureRedactionAuditTest` scans fixtures for credentials and PII.
    /// A fixture file containing a live Anthropic API key pattern must be caught.
    func test_fixtureRedactionAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Mimic Tests/Fixtures/backends/claude/streaming/simple-prompt/
        let fixtureDir = tmp
            .appendingPathComponent("backends/claude/streaming/simple-prompt", isDirectory: true)
        let offendingFile = fixtureDir.appendingPathComponent("request.sse")
        try write("""
            data: {"type":"message_start","message":{"id":"msg_01","type":"message"}}
            x-api-key: sk-ant-api03-fakekey1234567890abcdefghijklmnopqrstuvwxyz
            """, to: offendingFile)

        // Inline the detection logic.
        let patterns: [(label: String, regex: String)] = [
            ("anthropic-key", #"sk-ant-[A-Za-z0-9_-]+"#),
        ]

        func firstMatch(of pattern: String, in line: String) -> String? {
            guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
            return String(line[r])
        }

        var found = false
        if let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in content.components(separatedBy: "\n") {
                    for (_, regex) in patterns {
                        if firstMatch(of: regex, in: line) != nil {
                            found = true
                        }
                    }
                }
            }
        }

        XCTAssertTrue(
            found,
            "Sabotage: expected FixtureRedactionAuditTest to detect anthropic-key pattern, but found nothing"
        )
    }

    // MARK: - 6. WireNoveltyAuditTest sabotage

    /// `WireNoveltyAuditTest` flags JSON keys in `expected.jsonl` fixtures that
    /// aren't in `FixtureComparator.knownKeys`. A fixture row with an unknown
    /// key must be detected.
    func test_wireNoveltyAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Mimic a fixture directory with an expected.jsonl containing an unknown key.
        let fixtureDir = tmp.appendingPathComponent("backends/claude", isDirectory: true)
        let expectedFile = fixtureDir.appendingPathComponent("expected.jsonl")
        try write("""
            {"event":"token","text":"Hello","totally_unknown_field_xyz":"boom"}
            """, to: expectedFile)

        // Inline the detection logic: parse JSON lines and flag keys not in knownKeys.
        let knownKeys: Set<String> = [
            "event", "text", "prompt", "completion", "tool_name", "name",
            "arguments_contains", "call_id", "callId", "thinking_text",
            "signature", "finish_reason", "iterations",
        ]

        var novelties: [String] = []
        let contents = try String(contentsOf: expectedFile, encoding: .utf8)
        for (idx, line) in contents.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for k in raw.keys where k != "event" {
                if !knownKeys.contains(k) {
                    novelties.append("expected.jsonl:\(idx + 1):\(k)")
                }
            }
        }

        XCTAssertFalse(
            novelties.isEmpty,
            "Sabotage: expected WireNoveltyAuditTest to detect unknown key 'totally_unknown_field_xyz', but found no novelties"
        )
    }

    // MARK: - 7. ProviderParityFixtureCoverageTest sabotage

    /// `ProviderParityFixtureCoverageTest` verifies every backend in the manifest
    /// has a `streaming/simple-prompt/` fixture directory. A manifest entry with
    /// no matching directory must be caught.
    func test_providerParityFixtureCoverage_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a backends root with only "openai" — "claude" is deliberately missing.
        let backendsRoot = tmp.appendingPathComponent("backends", isDirectory: true)
        let openaiDir = backendsRoot
            .appendingPathComponent("openai/streaming/simple-prompt", isDirectory: true)
        try FileManager.default.createDirectory(at: openaiDir, withIntermediateDirectories: true)
        try write("", to: openaiDir.appendingPathComponent(".gitkeep"))

        // Inline the check logic: manifest entry "claude" must have a fixture directory.
        let manifest: [(backendName: String, fixtureDirectory: String)] = [
            (backendName: "openai.chat_completions", fixtureDirectory: "openai"),
            (backendName: "anthropic.messages",      fixtureDirectory: "claude"),  // deliberately missing
        ]

        var missing: [String] = []
        for entry in manifest {
            let dirURL = backendsRoot
                .appendingPathComponent(entry.fixtureDirectory)
                .appendingPathComponent("streaming")
                .appendingPathComponent("simple-prompt")

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                missing.append(entry.backendName)
            }
        }

        XCTAssertFalse(
            missing.isEmpty,
            "Sabotage: expected ProviderParityFixtureCoverageTest to detect 'claude' fixture directory missing, but found no missing entries"
        )
        XCTAssertTrue(
            missing.contains("anthropic.messages"),
            "Sabotage: expected 'anthropic.messages' in missing list, got: \(missing)"
        )
    }

    // MARK: - 8. PackageTopologyAuditTest sabotage

    /// `PackageTopologyAuditTest` checks that deleted stub files don't exist
    /// and that umbrella forbidden files are absent. Reintroducing a deleted
    /// stub must be detected.
    func test_packageTopologyAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Mimic Sources/ManifoldBackendsUmbrella/ with a reintroduced stub.
        let umbrella = tmp.appendingPathComponent("ManifoldBackendsUmbrella", isDirectory: true)
        let forbiddenFile = umbrella.appendingPathComponent("ClaudeBackend.swift")
        try write("""
            // Deliberately reintroduced — should trip the topology audit.
            class ClaudeBackend {}
            """, to: forbiddenFile)

        // Inline the "MUST NOT exist" check from PackageTopologyAuditTest.
        let forbidden = [
            "MLXBackend.swift",
            "LlamaBackend.swift",
            "FoundationBackend.swift",
            "ClaudeBackend.swift",
            "OpenAIBackend.swift",
            "OllamaBackend.swift",
            "SSECloudBackend.swift",
            "PinnedSessionDelegate.swift",
        ]

        var violations: [String] = []
        for name in forbidden {
            let path = umbrella.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                violations.append(name)
            }
        }

        XCTAssertFalse(
            violations.isEmpty,
            "Sabotage: expected PackageTopologyAuditTest to detect ClaudeBackend.swift in umbrella, but found no violations"
        )
        XCTAssertTrue(
            violations.contains("ClaudeBackend.swift"),
            "Sabotage: expected 'ClaudeBackend.swift' in violations, got: \(violations)"
        )
    }

    // MARK: - 9. SilentCatchAuditTest sabotage

    /// `SilentCatchAuditTest` forbids unapproved `try?` swallows in Sources/.
    /// A new file with a `try?` call that matches no approved idiom must be
    /// caught.
    func test_silentCatchAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let moduleDir = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        let offendingFile = moduleDir.appendingPathComponent("BadSwallow.swift")
        try write("""
            import Foundation
            func doSomething() {
                try? reallyImportantOperation()
            }
            """, to: offendingFile)

        // Inline the silent-try detection + idiom-approval logic from SilentCatchAuditTest.
        func lineContainsSilentTry(_ line: String) -> Bool {
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
            return line.range(of: #"\btry\?"#, options: .regularExpression) != nil
        }
        let approvedTryIdioms = ["JSONSerialization.", "FileManager.default.", "await Task.sleep"]
        func lineMatchesApprovedIdiom(_ line: String) -> Bool {
            approvedTryIdioms.contains {
                line.range(
                    of: #"\btry\?\s*"# + $0.replacingOccurrences(of: ".", with: "\\."),
                    options: .regularExpression
                ) != nil
            }
        }

        var offenders: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let content = try String(contentsOf: url, encoding: .utf8)
                for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard lineContainsSilentTry(line), !lineMatchesApprovedIdiom(line) else { continue }
                    offenders.append("\(url.lastPathComponent):\(idx + 1)")
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected SilentCatchAuditTest to detect the unapproved `try?` in BadSwallow.swift, but found no offenders"
        )
    }

    // MARK: - 10. UserDefaultsStandardAuditTest sabotage

    /// `UserDefaultsStandardAuditTest` forbids non-comment `UserDefaults.standard`
    /// references anywhere in Tests/. A new test file with a bare reference
    /// must be caught.
    func test_userDefaultsStandardAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let offendingFile = tmp.appendingPathComponent("BadDefaultsTests.swift")
        try write("""
            import XCTest
            final class BadDefaultsTests: XCTestCase {
                func test_something() {
                    UserDefaults.standard.set(true, forKey: "flag")
                }
            }
            """, to: offendingFile)

        // Inline the non-comment-hit detection from UserDefaultsStandardAuditTest.
        func findNonCommentHits(of needle: String, in content: String) -> [Int] {
            var hits: [Int] = []
            for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                if rawLine.contains(needle) { hits.append(index + 1) }
            }
            return hits
        }

        let content = try String(contentsOf: offendingFile, encoding: .utf8)
        let hits = findNonCommentHits(of: "UserDefaults.standard", in: content)

        XCTAssertFalse(
            hits.isEmpty,
            "Sabotage: expected UserDefaultsStandardAuditTest to detect the bare UserDefaults.standard reference, but found no hits"
        )
    }

    // MARK: - 11. TestSuiteSilentSkipAuditTest sabotage

    /// `TestSuiteSilentSkipAuditTest` forbids `try? XCTSkip*`/`try? XCTUnwrap`/
    /// `try? XCTFail` in Tests/. A new test file using `try? XCTSkipUnless`
    /// must be caught.
    func test_testSuiteSilentSkipAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let offendingFile = tmp.appendingPathComponent("BadSkipTests.swift")
        try write("""
            import XCTest
            final class BadSkipTests: XCTestCase {
                func test_something() {
                    try? XCTSkipUnless(false)
                }
            }
            """, to: offendingFile)

        // Inline the forbidden-pattern detection from TestSuiteSilentSkipAuditTest.
        let forbiddenPatterns = ["try? XCTSkip", "try? XCTUnwrap", "try? XCTFail"]
        var offenders: [(line: Int, text: String)] = []
        let content = try String(contentsOf: offendingFile, encoding: .utf8)
        for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
            for pattern in forbiddenPatterns where line.contains(pattern) {
                offenders.append((line: index + 1, text: line))
                break
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected TestSuiteSilentSkipAuditTest to detect `try? XCTSkipUnless`, but found no offenders"
        )
    }

    // MARK: - 12. AgentsMdAuditTest sabotage

    /// `AgentsMdAuditTest` forbids instructing consumers to call the deleted
    /// `vm.send(` method. A line calling it (without a negation cue) must be
    /// caught.
    func test_agentsMdAudit_detectsViolation() throws {
        try requireSabotageMode()

        // Inline the forbidden-call detection from
        // testDoesNotInstructConsumersToCallDeletedSendMethod.
        let offendingLine = "Call `vm.send(\"hello\")` to send a message."
        let regex = try NSRegularExpression(pattern: #"\b\w+\.send\("#)
        let nsLine = offendingLine as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: offendingLine, options: [], range: range)

        var found = false
        for match in matches {
            let matchedText = nsLine.substring(with: match.range)
            if matchedText.contains(".sendMessage(") { continue }
            found = true
        }

        XCTAssertTrue(
            found,
            "Sabotage: expected AgentsMdAuditTest to detect the forbidden `vm.send(` call, but found no match"
        )
    }

    // MARK: - 13. CuratedModelChecksumAuditTest sabotage

    /// `CuratedModelChecksumAuditTest` requires every `.gguf` curated-model
    /// entry to carry a valid 64-char-hex `expectedSHA256`. A missing or
    /// malformed value must be caught by the audit's filter logic.
    func test_curatedModelChecksumAudit_detectsViolation() throws {
        try requireSabotageMode()

        // Inline the missing-checksum filter from CuratedModelChecksumAuditTest.
        struct FakeEntry { let modelType: String; let expectedSHA256: String? }
        let entries = [FakeEntry(modelType: "gguf", expectedSHA256: nil)]
        let missing = entries.filter { $0.modelType == "gguf" && $0.expectedSHA256 == nil }

        XCTAssertFalse(
            missing.isEmpty,
            "Sabotage: expected the missing-checksum filter to flag a nil expectedSHA256 on a .gguf entry, but found no offenders"
        )

        // Inline the malformed-hex filter.
        let malformed = ["short-hash-not-64-chars"]
            .filter { $0.count != 64 || !$0.allSatisfy(\.isHexDigit) }

        XCTAssertFalse(
            malformed.isEmpty,
            "Sabotage: expected the 64-char-hex filter to flag a short/malformed checksum, but found no offenders"
        )
    }

    // MARK: - 14. GenerationEventClosedAuditTest sabotage

    /// `GenerationEventClosedAuditTest` forbids a run-level keyword (e.g.
    /// `runStarted`) appearing in the `ConversationEventKind` case-name
    /// surface. A synthetic surface containing one must be caught.
    func test_generationEventClosedAudit_detectsViolation() throws {
        try requireSabotageMode()

        // Inline the run-level-keyword containment check from
        // GenerationEventClosedAuditTest.
        let runLevelKeywords: Set<String> = [
            "runStarted", "runPaused", "runResumed", "runCompleted",
            "runCancelled", "runFailed", "stepStarted", "stepCompleted", "stepFailed",
        ]
        let sabotagedConversationEventKinds = ["messageInserted", "runStarted"]

        let offenders = runLevelKeywords.filter { sabotagedConversationEventKinds.contains($0) }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected GenerationEventClosedAuditTest to detect a run-level case name leaking into ConversationEventKind, but found no offenders"
        )
    }

    // MARK: - 15. ProtocolLocationAuditTest sabotage

    /// `ProtocolLocationAuditTest` asserts specific types live in specific
    /// modules via `String(reflecting:).hasPrefix(...)`. Feeding it a type
    /// known to live elsewhere (`ChatMessage`, which lives in
    /// `ManifoldInference`, not `ManifoldRuntime`) must fail the prefix
    /// check — confirming the assertion shape actually distinguishes a real
    /// mislocation rather than trivially passing.
    func test_protocolLocationAudit_detectsViolation() throws {
        try requireSabotageMode()

        let wrongModuleTypeName = String(reflecting: ChatMessage.self)

        XCTAssertFalse(
            wrongModuleTypeName.hasPrefix("ManifoldRuntime."),
            "Sabotage: expected ChatMessage (which lives in ManifoldInference) to fail a ManifoldRuntime-prefix check, but it unexpectedly passed — ProtocolLocationAuditTest's assertion would not catch a real mislocation"
        )
    }

    // MARK: - 16. ConversationEventClosedSwitchAuditTest sabotage

    /// `ConversationEventClosedSwitchAuditTest` forbids a `ConversationEvent`
    /// case name starting with the reserved `run`/`step` prefixes. A
    /// synthetic case name violating that must be caught.
    func test_conversationEventClosedSwitchAudit_detectsViolation() throws {
        try requireSabotageMode()

        // Inline the reserved-prefix check from ConversationEventClosedSwitchAuditTest.
        let reservedRunPrefixes = ["run", "step"]
        let sabotagedCaseName = "runStarted"

        let offenders = reservedRunPrefixes.filter { sabotagedCaseName.hasPrefix($0) }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected ConversationEventClosedSwitchAuditTest's reserved-prefix check to flag 'runStarted', but found no offenders"
        )
    }

    // MARK: - 17. SwiftTestingAuditTest sabotage

    /// `SwiftTestingAuditTest` forbids a single file declaring both an
    /// `XCTestCase` subclass and a `@Suite`/`@Test` annotation (the
    /// mixed-harness shape that trips the #681 libmalloc SIGABRT). A file
    /// combining both must be caught.
    func test_swiftTestingAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let targetDir = tmp.appendingPathComponent("ManifoldBackendsTests", isDirectory: true)
        let offendingFile = targetDir.appendingPathComponent("MixedHarness.swift")
        try write("""
            import XCTest
            import Testing
            final class MixedHarnessTests: XCTestCase {
                func test_something() {}
            }
            @Test func somethingElse() {}
            """, to: offendingFile)

        // Inline the two detectors from SwiftTestingAuditTest.
        func containsSwiftTestingAnnotation(_ content: String) -> Bool {
            for rawLine in content.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                if trimmed.contains("@Suite") || trimmed.contains("@Test") { return true }
            }
            return false
        }
        func containsXCTestCaseSubclass(_ content: String) -> Bool {
            let pattern = #"^\s*(?:final\s+|public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)*class\s+\w+(?:<[^>]+>)?\s*:[^{]*\bXCTestCase\b"#
            for rawLine in content.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
                if rawLine.range(of: pattern, options: .regularExpression) != nil { return true }
            }
            return false
        }

        let content = try String(contentsOf: offendingFile, encoding: .utf8)
        let mixed = containsSwiftTestingAnnotation(content) && containsXCTestCaseSubclass(content)

        XCTAssertTrue(
            mixed,
            "Sabotage: expected SwiftTestingAuditTest to detect a mixed-harness file (XCTestCase + @Suite/@Test), but the detectors did not both fire"
        )
    }

    // MARK: - 18. DocSourcePathReferenceAuditTest sabotage

    /// `DocSourcePathReferenceAuditTest` forbids a Markdown link target
    /// referencing a `Sources/…` path that doesn't exist on disk. A doc file
    /// linking to a nonexistent module file must be caught.
    func test_docSourcePathReferenceAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docFile = tmp.appendingPathComponent("FAKE_README.md")
        try write("""
            See [the module](Sources/ManifoldTotallyFakeModule/DoesNotExist.swift) for details.
            """, to: docFile)

        // Inline the link-target extraction + existence check from
        // DocSourcePathReferenceAuditTest.
        func linkTargets(in content: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#) else { return [] }
            let range = NSRange(content.startIndex..., in: content)
            return regex.matches(in: content, range: range).compactMap { match in
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: content) else { return nil }
                return String(content[r])
            }
        }

        let content = try String(contentsOf: docFile, encoding: .utf8)
        var missing: [String] = []
        for target in linkTargets(in: content) where target.contains("Sources/") {
            let resolved = URL(fileURLWithPath: target, relativeTo: tmp).standardizedFileURL
            if !FileManager.default.fileExists(atPath: resolved.path) {
                missing.append(target)
            }
        }

        XCTAssertFalse(
            missing.isEmpty,
            "Sabotage: expected DocSourcePathReferenceAuditTest to detect the broken Sources/ link, but found no missing references"
        )
    }

    // MARK: - 19. PackageTraitGateAuditTest sabotage

    /// `PackageTraitGateAuditTest` (rewritten #2095 to be manifest-driven)
    /// flags any trait-defining symbol (Hummingbird/HTTPTypes/SwiftSyntax-
    /// family/ManifoldMacrosPlugin) referenced as a dependency without its
    /// trait's `condition: .when(traits:)`. A synthetic manifest snippet
    /// that drops the condition on one such reference must be caught — the
    /// exact class of gap that shipped undetected for 5 real edges before
    /// this rewrite.
    func test_packageTraitGateAudit_detectsViolation() throws {
        try requireSabotageMode()

        // Inline the family-rule detection logic from the rewritten
        // PackageTraitGateAuditTest.
        let traitDefiningSymbols: [String: String] = [
            "ManifoldMacrosPlugin": "Macros",
            "Hummingbird": "Server",
        ]

        func lineIsDependencyReference(_ trimmed: String, to symbol: String) -> Bool {
            let prefixes = [
                ".target(name: \"\(symbol)\"",
                ".product(name: \"\(symbol)\"",
            ]
            if prefixes.contains(where: trimmed.hasPrefix) { return true }
            return trimmed == "\"\(symbol)\"," || trimmed == "\"\(symbol)\""
        }

        // Deliberately drops the Macros condition on ManifoldMacrosPlugin.
        let sabotagedManifestSnippet = """
            .target(
                name: "ManifoldSomeConsumer",
                dependencies: [
                    .target(name: "ManifoldMacrosPlugin"),
                ]
            ),
            """

        var offenders: [String] = []
        for (idx, rawLine) in sabotagedManifestSnippet.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            for (symbol, trait) in traitDefiningSymbols {
                guard lineIsDependencyReference(trimmed, to: symbol) else { continue }
                let hasCondition = trimmed.contains("condition:")
                    && trimmed.contains(".when(")
                    && trimmed.contains("traits: [\"\(trait)\"]")
                if !hasCondition {
                    offenders.append("line \(idx + 1): \(trimmed)")
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected the rewritten PackageTraitGateAuditTest to detect ManifoldMacrosPlugin referenced without its Macros condition, but found no offenders"
        )
    }

    // MARK: - 20. ContractTestSupportSplitAuditTest sabotage

    /// `ContractTestSupportSplitAuditTest` forbids a top-level `import XCTest`
    /// anywhere under `Sources/ManifoldTestSupport/` (the #1409 dyld-crash
    /// pattern). A reintroduced offending file must be caught.
    func test_contractTestSupportSplitAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let supportDir = tmp.appendingPathComponent("ManifoldTestSupport", isDirectory: true)
        let offendingFile = supportDir.appendingPathComponent("BadHelper.swift")
        try write("""
            import XCTest
            // Deliberately reintroducing the #1409 dyld-crash pattern.
            enum BadHelper {}
            """, to: offendingFile)

        // Inline the top-level-import detection from ContractTestSupportSplitAuditTest.
        var offenders: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: supportDir.path) {
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                let url = supportDir.appendingPathComponent(relative)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "import XCTest" {
                        offenders.append(relative)
                        break
                    }
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected ContractTestSupportSplitAuditTest to detect the top-level `import XCTest` in BadHelper.swift, but found no offenders"
        )
    }

    // MARK: - 21. UnlockedNonisolatedUnsafeTestSeamAuditTest sabotage

    /// `UnlockedNonisolatedUnsafeTestSeamAuditTest` (#2094) forbids an
    /// unallowlisted `nonisolated(unsafe) static var` declaration anywhere
    /// in Sources/. A new file with one, unguarded and not in the
    /// allowlist, must be caught.
    func test_unlockedNonisolatedUnsafeTestSeamAudit_detectsViolation() throws {
        try requireSabotageMode()

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let moduleDir = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        let offendingFile = moduleDir.appendingPathComponent("BadSeam.swift")
        try write("""
            import Foundation
            // Deliberately unguarded test-injection seam — no lock anywhere in this file.
            enum BadSeam {
                nonisolated(unsafe) static var _resolverForTesting: ((String) -> [String]?)? = nil
            }
            """, to: offendingFile)

        // Inline the detection logic from UnlockedNonisolatedUnsafeTestSeamAuditTest.
        // The real audit checks each hit against an allowlist; an empty temp
        // tree has no allowlist entries, so any hit here is an offender.
        func lineDeclaresNonisolatedUnsafeStaticVar(_ line: String) -> Bool {
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
            return line.contains("nonisolated(unsafe)") && line.contains("static var")
        }

        var offenders: [(file: String, line: Int)] = []
        if let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: tmp.path + "/", with: "")
                let content = try String(contentsOf: url, encoding: .utf8)
                for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if lineDeclaresNonisolatedUnsafeStaticVar(line) {
                        offenders.append((file: rel, line: idx + 1))
                    }
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "Sabotage: expected UnlockedNonisolatedUnsafeTestSeamAuditTest to detect the unguarded seam in BadSeam.swift, but found no offenders"
        )
    }
}
