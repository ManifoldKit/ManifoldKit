import XCTest
@testable import ManifoldCloudCore

/// Phase 2/B envelope guard: every cloud backend's stream loop must observe
/// `Task.isCancelled` (or call into a helper that does) so a host
/// `Task.cancel()` halts the generation within reasonable latency.
///
/// Modelled as a source-level audit — every `parseResponseStream` /
/// stream-loop method in `Sources/ManifoldCloud*` must mention either
/// `Task.isCancelled` or `try Task.checkCancellation()` in its body. A
/// runtime liveness test would require backend-specific instrumentation
/// hooks that don't exist yet (the loops drive `URLSession.AsyncBytes`
/// directly); the source-level guard catches the failure mode it's there
/// to prevent — a new backend file copy-pasted without a cancellation
/// check — without the instrumentation cost.
///
/// Phase 3 will upgrade this to a runtime contract once each backend
/// composes `CloudHTTPProviderAdapter` and the cancellation flow goes
/// through the envelope's `StreamFinalizer` consumer.
final class CancellationLivenessContractTest: XCTestCase {

    /// Files exempt from the audit (no stream loop / not a backend / etc.).
    /// Each entry is an inline rationale.
    private static let exemptFiles: Set<String> = [
        // Helper types — no stream loop of their own.
        // (ClaudePayloadParser.swift and OllamaPayloadHandler.swift were
        //  deleted in Phase 5 — their contents moved into the respective
        //  stream-extractor files.)
        "OllamaModelListService.swift",
        "OllamaModelProbe.swift",
        "OllamaStreamEventExtractor.swift",
        "CloudHTTPProviderAdapter.swift",
        "CloudMessageEncoder.swift",
        "CloudPayloadHandler.swift",
        "OpenAIAdapter.swift",
        "OllamaAdapter.swift",
        "OpenAIStreamEventExtractor.swift",
        "OpenAIToolEncoding.swift",
        // ManifoldCloudCore is enveloped, audited separately by other guards.
        // The envelope itself (SSECloudBackend.swift) is the canonical
        // cancellation observer.
    ]

    /// Backend files that have migrated to the adapter-routed path. The
    /// envelope's `CloudRoutedStreamParser` loop in
    /// ``SSECloudBackend`` owns the `Task.isCancelled` observation for
    /// these — the per-stream consumer also observes cancellation at
    /// `consume(payload:)` so phantom tool calls cannot fire mid-cancel.
    /// Listed explicitly so a regression that removes adapter routing
    /// from one of these files trips the audit immediately.
    private static let adapterRoutedBackends: Set<String> = [
        "OpenAIBackend.swift",
        "OllamaBackend.swift",
    ]

    func test_everyBackend_observesCancellation() throws {
        let files = try Self.locateCloudSourceDirs().flatMap(Self.enumerateSwiftFiles(under:))

        var offenders: [String] = []
        for fileURL in files {
            let name = fileURL.lastPathComponent
            if Self.exemptFiles.contains(name) { continue }
            // Only audit backend-shaped files (those with a stream loop).
            guard name.hasSuffix("Backend.swift") else { continue }

            // Adapter-routed backends delegate the stream loop and its
            // cancellation observation to `CloudRoutedStreamParser`
            // in `ManifoldCloudCore`. The audit accepts these as having
            // observed cancellation upstream — `adapterRouting` composition
            // is the gate.
            if Self.adapterRoutedBackends.contains(name) {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                if !content.contains("CloudHTTPProviderAdapter")
                    || !content.contains("configure(adapterRouting") {
                    offenders.append("\(name) (declared adapter-routed but missing routing wiring)")
                }
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let observesCancel = content.contains("Task.isCancelled")
                || content.contains("Task.checkCancellation()")
                || content.contains("try Task.checkCancellation")
                // Adapter-routed backends (`configure(adapterRouting:)`)
                // delegate cancellation to
                // `CloudRoutedStreamParser`, which is
                // the envelope's stream loop and contains the
                // canonical `Task.isCancelled` check. After Phase 3,
                // every cloud backend reaches this branch.
                || content.contains("configure(adapterRouting:")
            if !observesCancel {
                offenders.append(name)
            }
        }

        if !offenders.isEmpty {
            XCTFail("""
                Backend file(s) do not reference cancellation observation
                (`Task.isCancelled` or `Task.checkCancellation()`). Stream
                loops MUST observe cancellation or a host `Task.cancel()`
                will hang the generation. Add the observation inside the
                stream loop OR migrate the backend to the adapter path
                where the envelope owns cancellation.
                Offenders:
                \(offenders.map { "  - \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - Filesystem discovery

    /// The v0.48 product split spread the cloud backends across three
    /// targets; the audit walks all of them.
    private static let cloudSourceDirNames = [
        "Sources/ManifoldCloud",
        "Sources/ManifoldOllama",
        "Sources/ManifoldCloudSaaS",
    ]

    private static func locateCloudSourceDirs() throws -> [URL] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let dirs = cloudSourceDirNames.map { probe.appendingPathComponent($0, isDirectory: true) }
            if dirs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return dirs }
        }
        XCTFail("Could not locate the cloud source directories")
        return []
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return contents.filter { $0.pathExtension == "swift" }
    }
}
