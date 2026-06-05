import XCTest

/// Source-scan guard for the footgun audit's **class C — "asymmetric
/// siblings"**: a fix applied to one of N parallel implementations that never
/// propagates to the others.
///
/// The motivating regression (#1622/#1627): `MLXBackend` shipped with **no
/// `deinit`** while its sibling `LlamaBackend` released its C resources in
/// `deinit`. A dropped `MLXBackend` therefore leaked its per-UUID claim in
/// `MLXResourceArbiter` forever — and because the arbiter only fires
/// `MLX.Memory.clearCache()` on the *last* release, that guarantee then never
/// fired again and Metal buffers never returned to the OS.
///
/// The backend-level proof ("dropping the instance releases the claim") needs a
/// real Metal load and lives in `ManifoldMLXIntegrationTests` (Xcode-only). This
/// audit is the cheap, trait-independent CI tripwire that runs everywhere: each
/// backend that acquires a **process-global** resource must keep a `deinit`,
/// and that `deinit` must reference its release mechanism (so a no-op `deinit {}`
/// can't silence the guard). It would have failed the day the MLX `deinit` was
/// missing.
///
/// Lives in `ManifoldInferenceTests` (no traits) rather than
/// `ManifoldBackendsTests` (MLX/Llama-gated) so it runs in the default CI lane
/// regardless of which backend traits are enabled.
final class BackendDeinitSymmetryAuditTest: XCTestCase {

    /// A backend that acquires a process-global resource, plus the token that
    /// proves its `deinit` releases that resource.
    private struct ResourceReleasingBackend {
        let relativePath: String
        /// A substring that must appear in the file's `deinit` block, proving
        /// the teardown actually releases (not an empty `deinit {}`).
        let releaseToken: String
        let rationale: String
    }

    private static let backends: [ResourceReleasingBackend] = [
        ResourceReleasingBackend(
            relativePath: "ManifoldMLX/MLXBackend.swift",
            releaseToken: "MLXResourceArbiter.shared.release",
            rationale: "MLXBackend must release its MLXResourceArbiter claim in deinit, or the process-global cacheLimit/clearCache guarantee never fires again and Metal buffers never return to the OS (#1627)."
        ),
        ResourceReleasingBackend(
            relativePath: "ManifoldLlama/LlamaBackend.swift",
            releaseToken: "LlamaBackendProcessLifecycle.release",
            rationale: "LlamaBackend must release the process-global llama_backend latch (LlamaBackendProcessLifecycle.release) and free its C resources (unloadModel) in deinit — the sibling release path MLXBackend was missing."
        ),
    ]

    func test_resourceReleasingBackends_releaseInDeinit() throws {
        let sourcesURL = try Self.locateSourcesDirectory()

        for backend in Self.backends {
            let fileURL = sourcesURL.appendingPathComponent(backend.relativePath)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                XCTFail("""
                    Could not read \(backend.relativePath). If the backend was renamed or moved, update \
                    BackendDeinitSymmetryAuditTest.backends so the deinit-symmetry guard keeps tracking it.
                    """)
                continue
            }

            guard let deinitBody = Self.deinitBody(in: content) else {
                XCTFail("""
                    \(backend.relativePath) declares no `deinit`.
                    \(backend.rationale)
                    A sibling resource-releasing backend lost its deinit — exactly the class-C asymmetry the footgun audit flagged.
                    """)
                continue
            }

            XCTAssertTrue(
                deinitBody.contains(backend.releaseToken),
                """
                \(backend.relativePath) has a `deinit` but it does not reference `\(backend.releaseToken)` — \
                it looks like a no-op teardown that does not release the process-global resource.
                \(backend.rationale)
                """
            )
        }
    }

    // MARK: - Helpers

    /// Returns the text of the first `deinit { ... }` block in `content`,
    /// matched by brace balancing from the `deinit` keyword. Returns `nil` when
    /// no `deinit` is declared.
    private static func deinitBody(in content: String) -> String? {
        guard let deinitRange = content.range(of: #"\bdeinit\b"#, options: .regularExpression) else {
            return nil
        }
        guard let openBrace = content[deinitRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var idx = openBrace
        while idx < content.endIndex {
            let ch = content[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(content[content.index(after: openBrace)..<idx])
                }
            }
            idx = content.index(after: idx)
        }
        return nil
    }

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
        throw NSError(domain: "BackendDeinitSymmetryAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
    }
}
