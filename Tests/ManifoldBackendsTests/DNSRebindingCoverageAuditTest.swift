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
final class DNSRebindingCoverageAuditTest: XCTestCase {

    /// Files permitted to reference `DNSRebindingGuard` directly. Anything
    /// else fails the audit. Test code is exempt.
    private static let allowlistedRelativePaths: Set<String> = [
        // The guard's own definition.
        "ManifoldCloudCore/DNSRebindingGuard.swift",
        // The single envelope call site.
        "ManifoldCloudCore/SSECloudBackend.swift",
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

        var offenders: [(file: String, line: Int)] = []
        for root in cloudRoots {
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

    // MARK: - Filesystem discovery (mirrors SessionConstructionAuditTest)

    private struct SourceRoot {
        let name: String
        let url: URL
    }

    private static func locateCloudSourceRoots() throws -> [SourceRoot] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let sources = probe.appendingPathComponent("Sources", isDirectory: true)
            // v0.48 product split: the audit covers all four cloud targets.
            let names = ["ManifoldCloud", "ManifoldCloudCore", "ManifoldOllama", "ManifoldCloudSaaS"]
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
