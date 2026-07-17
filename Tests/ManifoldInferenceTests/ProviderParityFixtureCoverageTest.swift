import XCTest

/// Static-manifest audit that every registered backend has a
/// `Tests/Fixtures/backends/<directory>/streaming/simple-prompt/` directory.
///
/// This test lives in `ManifoldInferenceTests` (always compiled, no hardware
/// trait required) and runs without hardware gates. Local backend fixture
/// directories are stubs (`.gitkeep`) so the check passes even in CI where no
/// real model is present; the fixture contents are only populated by
/// `scripts/record-fixture.sh` in the nightly tier.
///
/// ## Capped allowlist
///
/// A narrow allowlist (max 2 entries) exists for backends whose fixture
/// directory has not been created yet. Every entry requires an inline
/// justification comment. Adding to the allowlist beyond the cap is rejected
/// by the assertion below — fix the root cause instead.
///
/// ## Extending the manifest
///
/// When a new backend is added:
/// 1. Add a `(backendName:, fixtureDirectory:)` entry to `manifest` below,
///    inside the appropriate `#if` guard.
/// 2. Create the stub directory + `.gitkeep` under
///    `Tests/Fixtures/backends/<directory>/streaming/simple-prompt/`.
/// 3. Remove the entry from `missingFixtureAllowlist` (or leave it absent —
///    the allowlist is only for genuinely-missing fixtures in the nightly tier).
///
/// The existence loop lives in ``missingBackends(backendsRoot:manifest:allowlist:)``
/// so the in-file sabotage test exercises the exact function the audit runs.
final class ProviderParityFixtureCoverageTest: XCTestCase {

    // MARK: - Manifest

    /// All registered backends with their fixture directory names.
    ///
    /// Cloud and local entries are all unconditional: the cloud families
    /// compile in every build since v0.48, and the local fixture stub
    /// directories exist even without hardware traits — they hold `.gitkeep`
    /// files that satisfy the coverage check.
    private static var manifest: [(backendName: String, fixtureDirectory: String)] {
        var entries: [(backendName: String, fixtureDirectory: String)] = []

        // SaaS backends — always compiled since v0.48.
        entries += [
            (backendName: "openai.chat_completions", fixtureDirectory: "openai"),
            (backendName: "openai.responses",        fixtureDirectory: "openai_responses"),
            (backendName: "anthropic.messages",      fixtureDirectory: "claude"),
        ]

        // Ollama backend — always compiled since v0.48.
        entries += [
            (backendName: "ollama.chat", fixtureDirectory: "ollama"),
        ]

        // Local backends — always compiled; fixture directories are stubs.
        entries += [
            (backendName: "mock.inference_backend", fixtureDirectory: "mock"),
            (backendName: "mlx.backend",            fixtureDirectory: "mlx"),
            (backendName: "llama.backend",          fixtureDirectory: "llama"),
            (backendName: "foundation.backend",     fixtureDirectory: "foundation"),
        ]

        return entries
    }

    // MARK: - Allowlist for genuinely-missing fixtures

    /// Backends for which the `streaming/simple-prompt/` fixture directory has
    /// not yet been populated. Every entry requires an inline justification.
    ///
    /// **Cap: 2 entries.** Adding beyond the cap means too many backends lack
    /// coverage — create the stub directory instead of growing this list.
    private static let missingFixtureAllowlist: Set<String> = [
        // No entries: all registered backends have at least a stub directory
        // with .gitkeep. Nightly fixtures are captured via record-fixture.sh.
    ]

    // MARK: - Test

    /// Verifies that every registered backend has a
    /// `streaming/simple-prompt/` directory under `Tests/Fixtures/backends/`.
    ///
    /// Fails with a descriptive list of missing backends so a contributor can
    /// see exactly which fixture stubs need to be created.
    func test_allRegisteredBackendsHaveStreamingSimplePromptFixture() throws {
        let fixturesRoot = try Self.locateFixturesRoot()
        let backendsRoot = fixturesRoot.appendingPathComponent("backends")

        let missing = Self.missingBackends(
            backendsRoot: backendsRoot,
            manifest: Self.manifest,
            allowlist: Self.missingFixtureAllowlist
        )

        XCTAssertTrue(missing.isEmpty, """
            The following registered backends are missing a \
            streaming/simple-prompt/ fixture directory:

            \(missing.joined(separator: "\n"))

            Fix: create the directory (with a .gitkeep stub) using:
              mkdir -p Tests/Fixtures/backends/<directory>/streaming/simple-prompt
              touch Tests/Fixtures/backends/<directory>/streaming/simple-prompt/.gitkeep

            Nightly fixture content is captured via scripts/record-fixture.sh.
            """)
    }

    /// Verifies the allowlist cap has not been exceeded.
    func test_missingFixtureAllowlistWithinCap() {
        XCTAssertLessThanOrEqual(
            Self.missingFixtureAllowlist.count,
            2,
            "missingFixtureAllowlist exceeds cap of 2. Create stub directories instead of growing the list."
        )
    }

    // MARK: - Sabotage (exercises the same `missingBackends(backendsRoot:manifest:allowlist:)` the audit runs)

    /// Plants a temp backends root with only the "openai" fixture directory
    /// present and asserts the REAL existence loop flags the missing
    /// "claude" entry but not the present "openai" one — and that adding
    /// the missing backend's name to the allowlist exempts it.
    func test_sabotage_missingBackendsFlagsPlantedGap() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-parity-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let openaiFixture = tmp
            .appendingPathComponent("openai/streaming/simple-prompt", isDirectory: true)
        try FileManager.default.createDirectory(at: openaiFixture, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: openaiFixture.appendingPathComponent(".gitkeep").path, contents: nil)

        let manifest: [(backendName: String, fixtureDirectory: String)] = [
            (backendName: "openai.chat_completions", fixtureDirectory: "openai"),
            (backendName: "anthropic.messages",      fixtureDirectory: "claude"),
        ]

        let missing = Self.missingBackends(backendsRoot: tmp, manifest: manifest, allowlist: [])
        XCTAssertTrue(missing.contains { $0.contains("anthropic.messages") })
        XCTAssertFalse(missing.contains { $0.contains("openai.chat_completions") })

        let exempted = Self.missingBackends(backendsRoot: tmp, manifest: manifest, allowlist: ["anthropic.messages"])
        XCTAssertTrue(exempted.isEmpty)
    }

    // MARK: - Detection

    static func missingBackends(
        backendsRoot: URL,
        manifest: [(backendName: String, fixtureDirectory: String)],
        allowlist: Set<String>
    ) -> [String] {
        var missing: [String] = []

        for entry in manifest {
            let dirURL = backendsRoot
                .appendingPathComponent(entry.fixtureDirectory)
                .appendingPathComponent("streaming")
                .appendingPathComponent("simple-prompt")

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: dirURL.path,
                isDirectory: &isDir
            )

            if !exists || !isDir.boolValue {
                // Allow entries that are in the explicit allowlist.
                if allowlist.contains(entry.backendName) { continue }
                missing.append(
                    "  \(entry.backendName) → Tests/Fixtures/backends/\(entry.fixtureDirectory)/streaming/simple-prompt/"
                )
            }
        }

        return missing
    }

    // MARK: - Fixture root discovery

    /// Walks up from `#filePath` until a `Tests/Fixtures/` directory is found.
    /// Mirrors the upwalk pattern used by ``InferenceBackendContractTests`` and
    /// ``LocalBackendContractTests`` so this suite works regardless of cwd.
    private static func locateFixturesRoot(
        filePath: StaticString = #filePath
    ) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ProviderParityFixtureCoverageTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"]
        )
    }
}
