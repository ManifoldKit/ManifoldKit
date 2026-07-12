import XCTest

/// Phase 2 audit: `DNSRebindingGuard` must only be referenced inside the
/// `SSECloudBackend` envelope, never directly by a provider-level backend
/// or adapter.
///
/// The guard is invoked exactly once per generation, in
/// `SSECloudBackend.generate(...)`, *before* the HTTP retry block. Moving
/// the call into a per-provider override would either:
///
/// - duplicate the guard (running it per retry attempt, which thrashes
///   the resolver and can pin the wrong IP on a retry), or
/// - bypass it entirely (a new provider override forgetting to call it).
///
/// Both classes of bug are caught by this audit: the guard is a single
/// envelope-level concern, full stop. `SSECloudBackend.swift` is the
/// only allowed reference in `Sources/ManifoldCloud*` (the guard's own
/// file in `ManifoldCloudCore` is permitted since that *is* the guard).
///
/// The detection logic lives in ``offenders(underRoots:)`` so the in-file
/// sabotage test exercises the exact function the audit runs — not a copy.
final class DNSRebindingCoverageAuditTest: XCTestCase {

    /// Files permitted to reference `DNSRebindingGuard` directly. Anything
    /// else fails the audit. Test code is exempt.
    private static let allowlistedRelativePaths: Set<String> = [
        // The guard's own definition.
        "ManifoldCloudCore/DNSRebindingGuard.swift",
        // The single envelope call site.
        "ManifoldCloudCore/SSECloudBackend.swift",
        // Non-SSE cloud helpers share the same pre-flight via pinnedData.
        "ManifoldCloudCore/ConnectAddressPinningDelegate.swift",
        // Comment reference only — `URLSessionProvider`'s docs mention
        // the guard to explain how the pinned session interoperates.
        "ManifoldCloudCore/URLSessionProvider.swift",
        // TODO(phase-3): Ollama's request paths predate the envelope-only
        // policy. Both call sites validate before constructing per-provider
        // helper requests (model list, manifest probe). Phase 3 routes
        // those through the adapter's envelope so this allowlist shrinks
        // to two entries.
        "ManifoldOllama/OllamaBackend.swift",
        "ManifoldOllama/OllamaModelListService.swift",
    ]

    func test_DNSRebindingGuard_isReferencedOnlyInsideEnvelope() throws {
        let cloudRoots = try Self.locateCloudSourceRoots()
        XCTAssertFalse(cloudRoots.isEmpty)

        let offenders = try Self.offenders(underRoots: cloudRoots)

        if !offenders.isEmpty {
            let listing = offenders.map { "  \($0.file):\($0.line)" }.joined(separator: "\n")
            XCTFail("""
                DNSRebindingGuard referenced outside the envelope.
                The guard runs once per generation in SSECloudBackend; per-
                provider references either duplicate it (per-retry thrash)
                or skip it. Move the call back to the envelope.
                Offenders:
                \(listing)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `offenders(underRoots:)` the audit runs)

    /// Plants a direct `DNSRebindingGuard` reference in a temp tree shaped
    /// like a cloud source root and asserts the REAL detection function flags
    /// it — and that an allowlisted envelope path stays exempt.
    func test_sabotage_detectsGuardReferenceOutsideEnvelope() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dns-rebinding-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldCloudSaaS", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation
        // Deliberately referencing DNSRebindingGuard outside the envelope.
        func check() { _ = DNSRebindingGuard() }
        """.write(to: root.appendingPathComponent("GeminiBackend.swift"), atomically: true, encoding: .utf8)

        let offenders = try Self.offenders(underRoots: [SourceRoot(name: "ManifoldCloudSaaS", url: root)])
        XCTAssertEqual(offenders.count, 1, "The planted DNSRebindingGuard reference must be flagged")
        XCTAssertEqual(offenders.first?.file, "ManifoldCloudSaaS/GeminiBackend.swift")

        // The allowlisted envelope call site must stay exempt for the same content.
        let coreRoot = tmp.appendingPathComponent("ManifoldCloudCore", isDirectory: true)
        try FileManager.default.createDirectory(at: coreRoot, withIntermediateDirectories: true)
        try """
        func generate() { _ = DNSRebindingGuard() }
        """.write(to: coreRoot.appendingPathComponent("SSECloudBackend.swift"), atomically: true, encoding: .utf8)
        let envelopeOffenders = try Self.offenders(underRoots: [SourceRoot(name: "ManifoldCloudCore", url: coreRoot)])
        XCTAssertTrue(envelopeOffenders.isEmpty, "The allowlisted envelope file must not be flagged")
    }

    // MARK: - Detection

    static func offenders(underRoots roots: [SourceRoot]) throws -> [(file: String, line: Int)] {
        var offenders: [(file: String, line: Int)] = []
        for root in roots {
            let swiftFiles = try Self.enumerateSwiftFiles(under: root.url)
            for fileURL in swiftFiles {
                let rel = "\(root.name)/" + fileURL.path
                    .replacingOccurrences(of: root.url.path + "/", with: "")
                if Self.allowlistedRelativePaths.contains(rel) { continue }
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                    if line.contains("DNSRebindingGuard") {
                        offenders.append((file: rel, line: idx + 1))
                    }
                }
            }
        }
        return offenders
    }

    // MARK: - Filesystem discovery (mirrors SessionConstructionAuditTest)

    struct SourceRoot {
        let name: String
        let url: URL
    }

    private static func locateCloudSourceRoots() throws -> [SourceRoot] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let sources = probe.appendingPathComponent("Sources", isDirectory: true)
            // v0.48 product split: the audit covers all four cloud targets.
            let names = ["ManifoldCloudCore", "ManifoldOllama", "ManifoldCloudSaaS"]
            let roots = names.map {
                SourceRoot(name: $0, url: sources.appendingPathComponent($0, isDirectory: true))
            }
            if roots.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) {
                return roots
            }
        }
        return []
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }
}
