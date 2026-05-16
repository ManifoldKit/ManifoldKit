import XCTest
import Foundation

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
}
