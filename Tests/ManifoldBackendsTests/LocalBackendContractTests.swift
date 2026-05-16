import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Parameterised contract suite for local inference backends.
///
/// Phase 4 of the cross-backend unification plan. Parallel to
/// ``InferenceBackendContractTests`` (which covers cloud backends via the
/// ``CloudPayloadHandler`` + ``StreamFinalizer`` layer), this suite tests the
/// ``InferenceBackend/generate(prompt:systemPrompt:config:)`` layer directly.
///
/// Local backends — MLX, Llama, Foundation — do not route through
/// ``CloudPayloadHandler``; they implement `generate()` themselves. Their
/// contract surface is the ``GenerationEvent`` stream that `generate()`
/// produces. This suite verifies that stream against on-disk JSONL fixtures
/// under `Tests/Fixtures/backends/<name>/streaming/simple-prompt/expected.jsonl`.
///
/// **Participants**: ``LocalParticipant`` enumerates all local backends. This
/// PR registers only ``MockInferenceBackend`` as the first participant. MLX,
/// Llama, and Foundation participants are added in follow-up PRs inside the
/// `participants` computed property, gated by the appropriate trait or
/// `#available` check.
///
/// **Always compiled**: the file has no outer `#if` guard because
/// ``ManifoldTestSupport`` and ``ManifoldInference`` are always linked.
/// Per-participant `#if`/`#available` guards live inside the `participants`
/// property.
final class LocalBackendContractTests: XCTestCase {

    // MARK: - Participants

    /// Static description of one local backend's contract surface.
    ///
    /// Unlike ``InferenceBackendContractTests.Participant``, there is no
    /// `handler` or `finalizer` — local backends are exercised through the
    /// `generate()` call directly. The ``makeBackend`` factory must return a
    /// backend that has already been loaded (or is pre-loaded, like
    /// ``MockInferenceBackend``).
    ///
    /// Marked `@unchecked Sendable` because the factory closure captures
    /// backend construction state. All captured types (MockInferenceBackend,
    /// stdlib values) are safe to construct on any thread.
    struct LocalParticipant: @unchecked Sendable {
        let label: String
        let fixtureDirectory: String
        let capabilities: BackendCapabilities
        /// Factory that returns a backend ready to serve `generate()`.
        /// For ``MockInferenceBackend``, `isModelLoaded` is set to `true` by
        /// calling `loadModel()` inside this factory before returning.
        let makeBackend: @Sendable () async -> any InferenceBackend
    }

    /// MockInferenceBackend participant.
    ///
    /// Scripted to yield `["Hello", " ", "world"]`, matching
    /// `Tests/Fixtures/backends/mock/streaming/simple-prompt/expected.jsonl`.
    private static let mockParticipant = LocalParticipant(
        label: "mock",
        fixtureDirectory: "mock",
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            supportsStreaming: true,
            isRemote: false
        ),
        makeBackend: {
            let backend = MockInferenceBackend()
            // MockInferenceBackend.loadModel only throws when shouldThrowOnLoad
            // is set; the default factory never sets it, so this is safe to
            // ignore via a do/catch rather than try?.
            do {
                try await backend.loadModel(
                    from: URL(string: "unused:")!,
                    plan: .testStub(effectiveContextSize: 512)
                )
            } catch {
                // No-op: default MockInferenceBackend never throws on load.
            }
            backend.tokensToYield = ["Hello", " ", "world"]
            return backend
        }
    )

    /// All participants registered for this suite.
    ///
    /// Extend this list when adding MLX / Llama / Foundation participants.
    /// Gate each additional entry with `#if MLX`, `#if Llama`, or
    /// `#available(macOS 26, iOS 26, *)` as appropriate — the outer file has
    /// no trait guard, so per-participant guards are the only safe seam.
    private static var participants: [LocalParticipant] {
        var list: [LocalParticipant] = []
        list.append(mockParticipant)
        // MLX participant: #if MLX — follow-up PR
        // Llama participant: #if Llama — follow-up PR
        // Foundation participant: #available(macOS 26, iOS 26, *) — follow-up PR
        return list
    }

    // MARK: - Scenarios

    /// Drives `backend.generate()` with a simple prompt, collects `.token`
    /// events, and compares them against the on-disk `expected.jsonl` fixture.
    ///
    /// Runs for every participant whose capabilities claim
    /// `supportsStreaming == true`. All registered participants in this PR
    /// claim streaming.
    func test_generate_simplePrompt_emitsTokensInOrder() async throws {
        for p in Self.participants where p.capabilities.supportsStreaming {
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

            XCTAssertFalse(emitted.isEmpty, "[\(p.label)] expected at least one token event")
            let fixture = try fixtureURL(for: p, scenario: "streaming/simple-prompt", file: "expected.jsonl")
            XCTAssertEventsMatch(actual: emitted, fixtureURL: fixture)
        }
    }

    /// After draining the stream completely, `isGenerating` must be `false`.
    ///
    /// The mock sets `isGenerating = false` at the end of its emission task,
    /// before finishing the stream. This test drains the full stream and then
    /// asserts the flag.
    func test_generate_stopsGenerating_afterStreamEnd() async throws {
        for p in Self.participants where p.capabilities.supportsStreaming {
            let backend = await p.makeBackend()
            let stream = try backend.generate(
                prompt: "ping",
                systemPrompt: nil,
                config: GenerationConfig()
            )

            for try await _ in stream.events {}

            XCTAssertFalse(backend.isGenerating, "[\(p.label)] isGenerating must be false after stream ends")
        }
    }

    /// Cancelling the stream mid-way halts emission within a bounded deadline.
    ///
    /// Uses ``SlowMockBackend`` directly (not participant fixture path) because
    /// this is a universal invariant about cooperative cancellation — it does
    /// not depend on fixture content. The slow backend delays 5 seconds per
    /// token; a 20-token stream would run for ~100s without cancellation.
    /// We cancel early and verify fewer than 20 tokens were seen, proving the
    /// stream stopped rather than exhausted.
    func test_generate_cancelMidStream_haltsBelowBudget() async throws {
        // A slow backend: 20 tokens at 5s per token = ~100s without cancellation.
        let backend = SlowMockBackend(tokenCount: 20, delayMilliseconds: 5_000)

        let stream = try backend.generate(
            prompt: "count",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Collect tokens in a child Task whose return value is read after
        // cancellation, avoiding the Swift 6 data-race on a mutable captured
        // variable shared between the outer function and the Task closure.
        let drainTask = Task<Int, Error> {
            var count = 0
            for try await event in stream.events {
                if case .token = event {
                    count += 1
                }
            }
            return count
        }

        // Yield briefly so the stream emission task starts.
        try await Task.sleep(for: .milliseconds(50))

        // Cancel via the drain task rather than stopGeneration() because this
        // tests cooperative cancellation (Task.isCancelled checks in the backend).
        drainTask.cancel()

        // Wait for cancellation to propagate. The 200ms window is generous
        // given that SlowMockBackend checks Task.isCancelled before each token.
        try await Task.sleep(for: .milliseconds(200))

        // The task was cancelled; its result is either the count at
        // cancellation time or a CancellationError. Both prove that not all
        // 20 tokens were consumed.
        let tokensSeen: Int
        do {
            tokensSeen = try await drainTask.value
        } catch is CancellationError {
            tokensSeen = 0
        }

        XCTAssertLessThan(
            tokensSeen,
            20,
            "cancel mid-stream must halt emission before all 20 tokens are yielded"
        )
    }

    // MARK: - Fixture loading

    private func fixtureURL(
        for participant: LocalParticipant,
        scenario: String,
        file: String,
        filePath: StaticString = #filePath
    ) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent(participant.fixtureDirectory)
            .appendingPathComponent(scenario)
            .appendingPathComponent(file)
    }

    /// Walks up from `#filePath` until a `Tests/Fixtures/` directory is found.
    /// Mirrors the upwalk pattern used by ``InferenceBackendContractTests`` and
    /// other audit tests so the suite works regardless of cwd.
    private static func locateFixturesRoot(filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "LocalBackendContractTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
