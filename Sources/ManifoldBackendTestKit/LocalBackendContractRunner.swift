import XCTest
import Foundation
import ManifoldInference

/// Static description of one local backend's contract surface.
///
/// Parameterizes ``LocalBackendContractRunner`` so each backend package
/// (in-repo mock/Foundation, companion manifold-mlx / manifold-llama) declares
/// its own participant in its own test target and runs the shared scenarios
/// against it. Unlike the cloud-side `InferenceBackendContractTests`
/// participant, there is no `handler` or `finalizer` — local backends are
/// exercised through the `generate()` call directly.
///
/// When `requiresSlowTests` is `true`, scenarios that call `generate()`
/// skip themselves unless the `RUN_SLOW_TESTS=1` environment variable is
/// set (and skip in the simulator, where Metal is unavailable). This keeps
/// the per-PR CI lane fast by deferring hardware-gated generation assertions
/// to the nightly tier.
///
/// Marked `@unchecked Sendable` because the factory closure captures
/// backend construction state. All captured types must be safe to construct
/// on any thread.
public struct LocalBackendContractParticipant: @unchecked Sendable {
    public let label: String
    /// Directory under `<fixturesRoot>/backends/` holding this backend's
    /// scenario fixtures (e.g. `mlx`, `llama`, `mock`).
    public let fixtureDirectory: String
    public let capabilities: BackendCapabilities
    /// When `true`, generation scenarios skip unless `RUN_SLOW_TESTS=1`.
    /// Set for local backends that require real hardware and a model file
    /// (MLX, Llama). `false` for scripted mocks.
    public let requiresSlowTests: Bool
    /// Factory that returns a backend ready to serve `generate()`.
    /// For scripted mocks, load the model inside this factory before
    /// returning; hardware backends may return their zero state and rely on
    /// the slow-test gate.
    public let makeBackend: @Sendable () async -> any InferenceBackend

    public init(
        label: String,
        fixtureDirectory: String,
        capabilities: BackendCapabilities,
        requiresSlowTests: Bool,
        makeBackend: @escaping @Sendable () async -> any InferenceBackend
    ) {
        self.label = label
        self.fixtureDirectory = fixtureDirectory
        self.capabilities = capabilities
        self.requiresSlowTests = requiresSlowTests
        self.makeBackend = makeBackend
    }
}

/// Shared scenario implementations for the local-backend contract suite.
///
/// Each adopting test target declares one participant per backend and one
/// `test_…` method per scenario calling into this runner — XCTest does not
/// discover protocol-extension tests, so the concrete test methods live with
/// the adopter. See the ``ManifoldBackendTestKit`` DocC catalog for the full
/// adoption walkthrough, including the non-vacuity expectation (every adopting
/// suite must execute at least one scenario per participant; a suite whose
/// scenarios all skip is evidence of a mis-wired gate, not a green contract).
public enum LocalBackendContractRunner {

    /// Drives `backend.generate()` with a simple prompt, collects `.token`
    /// events, and compares them against the on-disk `expected.jsonl` fixture
    /// at `<fixturesRoot>/backends/<fixtureDirectory>/streaming/simple-prompt/expected.jsonl`.
    ///
    /// Skips (rather than fails) for hardware-gated participants when
    /// `RUN_SLOW_TESTS != 1` or when running in the simulator.
    public static func assertSimplePromptEmitsTokensInOrder(
        participant p: LocalBackendContractParticipant,
        fixturesRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try skipIfHardwareGated(p)
        let backend = await p.makeBackend()
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var emitted: [GenerationEvent] = []
        for try await event in stream.events {
            emitted.append(event)
        }

        XCTAssertFalse(emitted.isEmpty, "[\(p.label)] expected at least one token event",
                       file: file, line: line)
        let fixture = fixturesRoot
            .appendingPathComponent("backends")
            .appendingPathComponent(p.fixtureDirectory)
            .appendingPathComponent("streaming/simple-prompt")
            .appendingPathComponent("expected.jsonl")
        XCTAssertEventsMatch(actual: emitted, fixtureURL: fixture, file: file, line: line)
    }

    /// After draining the stream completely, `isGenerating` must be `false`.
    public static func assertStopsGeneratingAfterStreamEnd(
        participant p: LocalBackendContractParticipant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try skipIfHardwareGated(p)
        let backend = await p.makeBackend()
        let stream = try backend.generate(
            prompt: "ping",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        for try await _ in stream.events {}

        XCTAssertFalse(backend.isGenerating,
                       "[\(p.label)] isGenerating must be false after stream ends",
                       file: file, line: line)
    }

    /// Capability-gate conformance (footgun audit class A — #1623).
    ///
    /// `requiredCapabilities` enforcement previously lived only in
    /// `RouterBackend`; #1630 moved it into `generateEnforcingCapabilities` so a
    /// host running against a single concrete backend gets the same fail-fast.
    /// `.minContextTokens(Int.max)` is a requirement no backend can satisfy, so
    /// the gate fires uniformly without per-backend reasoning — and because
    /// enforcement throws *before* `generate()`, it runs in the fast lane for
    /// hardware-gated participants too (no model, no Metal, no RUN_SLOW_TESTS).
    public static func assertCapabilityGateDisclaimedRequirementThrows(
        participant p: LocalBackendContractParticipant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var config = GenerationConfig()
        config.requiredCapabilities = [.minContextTokens(Int.max)]
        let backend = await p.makeBackend()
        XCTAssertThrowsError(
            try backend.generateEnforcingCapabilities(prompt: "hi", systemPrompt: nil, config: config),
            "[\(p.label)] must reject a requirement it cannot satisfy",
            file: file, line: line
        ) { error in
            guard case InferenceError.noBackendSatisfiesRequirements = error else {
                XCTFail("[\(p.label)] threw \(error); expected noBackendSatisfiesRequirements",
                        file: file, line: line)
                return
            }
        }
    }

    // MARK: - Gating helpers

    /// Throws `XCTSkip` when `participant` is hardware-gated and the slow-test
    /// preconditions (RUN_SLOW_TESTS=1, real device with Metal) are not met.
    public static func skipIfHardwareGated(
        _ p: LocalBackendContractParticipant
    ) throws {
        guard p.requiresSlowTests else { return }
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RUN_SLOW_TESTS"] != "1",
            "[\(p.label)] contract scenarios require a real model — set RUN_SLOW_TESTS=1 and ensure a model is present"
        )
        try XCTSkipIf(isSimulator(), "[\(p.label)] Metal unavailable in simulator")
    }

    /// Returns `true` when running inside the iOS/macOS Simulator, where Metal
    /// (and therefore MLX / Llama) is unavailable.
    public static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Fixture location

    /// Walks up from the caller's `#filePath` until a `Tests/Fixtures/`
    /// directory is found. Works in any adopting repo that keeps the
    /// `Tests/Fixtures/backends/<name>/…` layout, regardless of cwd.
    public static func locateFixturesRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "LocalBackendContractRunner", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ walking up from \(filePath)"
        ])
    }
}
