import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceSwiftData

/// Coverage for ``ManifoldBootstrap/addToolSources(_:)`` — the first test
/// coverage this public primitive has ever had (#2440).
///
/// Before this PR, `addToolSources(_:)` forwarded straight to
/// `ConversationRuntime.updateSessionToolSources(_:)`, which **replaces** the
/// full source list. Every call to `addToolSources(_:)` therefore silently
/// erased whatever was registered before it — including sources passed to
/// `ManifoldBootstrap.build(sessionToolSources:)` at construction time. See
/// docs/MIGRATION-additive-tool-sources.md.
///
/// Each test drives one real turn through a ``MockInferenceBackend`` and
/// inspects `mock.lastConfig?.tools` — the same technique
/// `ConversationRuntimeRebindTests` (`ManifoldRuntimeTests`) uses to observe
/// the executor's per-turn advertised-tools snapshot. There is no public
/// accessor for "currently registered session tool sources" on
/// `ManifoldBootstrap`, and adding one is out of scope here (Public API
/// design policy: don't widen surface unless the PR body claims it) — a real
/// turn is the only observable proof that a source is actually wired.
@MainActor
final class ManifoldBootstrapAddToolSourcesTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal `SessionToolSource` whose advertised tool name is
    /// parameterized. Two instances of the same `struct` type share a
    /// dynamic type — used to exercise de-duplication. `StubToolSourceA`
    /// and `StubToolSourceB` are distinct types, used to exercise
    /// accumulation across genuinely different sources.
    private struct StubToolSourceA: SessionToolSource {
        let toolName: String
        func toolDefinitions(for session: ChatSession) async -> [ToolDefinition] {
            [ToolDefinition(name: toolName, description: "stub A", parameters: .object([:]))]
        }
        func resolve(toolName: String, arguments: String, session: ChatSession) async throws -> ToolResult {
            ToolResult(callId: "", content: "")
        }
    }

    private struct StubToolSourceB: SessionToolSource {
        let toolName: String
        func toolDefinitions(for session: ChatSession) async -> [ToolDefinition] {
            [ToolDefinition(name: toolName, description: "stub B", parameters: .object([:]))]
        }
        func resolve(toolName: String, arguments: String, session: ChatSession) async throws -> ToolResult {
            ToolResult(callId: "", content: "")
        }
    }

    /// Tool-capable `MockInferenceBackend`: the executor's union of registry +
    /// sessionToolSources can produce a non-empty `tools` list, and
    /// `GenerationQueue.enqueue` throws if `tools.isEmpty == false` while the
    /// backend reports `supportsToolCalling == false`.
    private func makeMockBackend() -> MockInferenceBackend {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        mock.isModelLoaded = true
        mock.tokensToYield = ["ok"]
        return mock
    }

    private func makeBootstrap(
        sessionToolSources: [any SessionToolSource],
        mock: MockInferenceBackend,
        label: String
    ) throws -> ManifoldBootstrap {
        try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "ToolSources Tests",
                bundleIdentifier: "com.manifoldkit.bootstrap-toolsources-tests.\(label).\(UUID().uuidString)"
            ),
            inferenceService: InferenceService(backend: mock, name: "Mock"),
            sessionToolSources: sessionToolSources,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
    }

    /// Drains `runtime.events` until `.streamFinished` (or a 5s deadline),
    /// mirroring `ConversationRuntimeRebindTests`'s helper of the same shape.
    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        let task = Task {
            var collected: [ConversationEvent] = []
            for await event in runtime.events {
                collected.append(event)
                if case .streamFinished = event { return collected }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw CocoaError(.userCancelled)
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    /// Inserts a fresh session, runs one `.send` turn, and returns the tool
    /// names the backend observed on that turn's `GenerationConfig`.
    private func advertisedToolNames(
        bootstrap: ManifoldBootstrap,
        mock: MockInferenceBackend
    ) async throws -> [String] {
        let sessionID = UUID()
        try await bootstrap.persistence.insertSession(ChatSession(id: sessionID, title: "ToolSources"))
        _ = try await bootstrap.conversationRuntime.processTurn(
            TurnInput(sessionID: sessionID, kind: .send(text: "hi"))
        )
        _ = try await collectUntilStreamFinished(from: bootstrap.conversationRuntime)
        return (mock.lastConfig?.tools ?? []).map(\.name)
    }

    // MARK: - Regression: addToolSources must not clobber build-time sources (#2440)

    /// Demonstrated red on `main`: `addToolSources(_:)` used to call
    /// `conversationRuntime.updateSessionToolSources(_:)` directly, which
    /// **replaces** the full set. Installing a source at
    /// `ManifoldBootstrap.build(sessionToolSources:)`-construction-time and
    /// then registering a second via `addToolSources(_:)` silently dropped
    /// the first. After the fix, both must be advertised together.
    func test_addToolSources_doesNotClobberBuildTimeSource() async throws {
        let mock = makeMockBackend()
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "ToolSources Regression",
                bundleIdentifier: "com.manifoldkit.bootstrap-toolsources-tests.regression.\(UUID().uuidString)"
            ),
            inferenceService: InferenceService(backend: mock, name: "Mock"),
            sessionToolSources: [StubToolSourceA(toolName: "build_time_tool")],
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let bootstrap = try await task.value

        // Register a second, independently-typed source via the public
        // accumulator — simulates a different part of the host app wiring
        // its own tool source after construction.
        await bootstrap.addToolSources([StubToolSourceB(toolName: "added_tool")])

        let advertised = try await advertisedToolNames(bootstrap: bootstrap, mock: mock)

        XCTAssertTrue(advertised.contains("build_time_tool"),
            "build-time sessionToolSources must survive a later addToolSources(_:) call; got: \(advertised)")
        XCTAssertTrue(advertised.contains("added_tool"),
            "addToolSources(_:)-registered source must be advertised; got: \(advertised)")
        // Sabotage-evidence: revert addToolSources(_:) to
        //   `await conversationRuntime.updateSessionToolSources(sources)` (the
        //   pre-fix body) → build_time_tool disappears from `advertised`;
        //   the first assertion trips. This is the literal defect #2440
        //   reports; see the PR body for the red captured against main.
    }

    // MARK: - Append: two independent calls accumulate

    /// Two separate `addToolSources(_:)` calls registering different-typed
    /// sources must both be advertised — the pure accumulate case, with no
    /// build-time source involved.
    func test_addToolSources_appendsAcrossMultipleCalls() async throws {
        let mock = makeMockBackend()
        let bootstrap = try makeBootstrap(sessionToolSources: [], mock: mock, label: "append")

        await bootstrap.addToolSources([StubToolSourceA(toolName: "tool_a")])
        await bootstrap.addToolSources([StubToolSourceB(toolName: "tool_b")])

        let advertised = try await advertisedToolNames(bootstrap: bootstrap, mock: mock)

        XCTAssertTrue(advertised.contains("tool_a"),
            "first addToolSources(_:) call's source must survive a second call; got: \(advertised)")
        XCTAssertTrue(advertised.contains("tool_b"),
            "second addToolSources(_:) call's source must be advertised; got: \(advertised)")
    }

    // MARK: - De-dup: same dynamic type replaces its own prior entry only

    /// Registering a new instance of a type that is already registered
    /// replaces only that entry — the de-duplication key is the source's
    /// *dynamic type*, not its identity. A different, previously-registered
    /// type must be untouched by the dedup.
    func test_addToolSources_deduplicatesByDynamicType() async throws {
        let mock = makeMockBackend()
        let bootstrap = try makeBootstrap(sessionToolSources: [], mock: mock, label: "dedup")

        await bootstrap.addToolSources([
            StubToolSourceA(toolName: "a_v1"),
            StubToolSourceB(toolName: "b_untouched")
        ])
        // Re-register a NEW StubToolSourceA instance — same dynamic type,
        // different tool name. Must replace a_v1, not add alongside it.
        await bootstrap.addToolSources([StubToolSourceA(toolName: "a_v2")])

        let advertised = try await advertisedToolNames(bootstrap: bootstrap, mock: mock)

        XCTAssertFalse(advertised.contains("a_v1"),
            "re-registering StubToolSourceA must replace the earlier instance's tool, not add to it; got: \(advertised)")
        XCTAssertTrue(advertised.contains("a_v2"),
            "the newest StubToolSourceA registration must be advertised; got: \(advertised)")
        XCTAssertTrue(advertised.contains("b_untouched"),
            "de-duplicating StubToolSourceA must not disturb an unrelated StubToolSourceB registration; got: \(advertised)")
        // Sabotage-evidence: drop the `merged.removeAll { ... }` de-dup line
        //   in addToolSources(_:) → both a_v1 and a_v2 appear; the
        //   XCTAssertFalse trips.
    }

    // MARK: - Empty array: a no-op call must not clear existing registrations

    /// `addToolSources([])` must be a true no-op against the accumulated
    /// set — it must not reset it to empty. This is the failure mode the old
    /// replace-semantics implementation would have hit trivially.
    func test_addToolSources_emptyArray_doesNotClearExisting() async throws {
        let mock = makeMockBackend()
        let bootstrap = try makeBootstrap(sessionToolSources: [], mock: mock, label: "empty")

        await bootstrap.addToolSources([StubToolSourceA(toolName: "persists")])
        await bootstrap.addToolSources([])

        let advertised = try await advertisedToolNames(bootstrap: bootstrap, mock: mock)

        XCTAssertTrue(advertised.contains("persists"),
            "addToolSources([]) must not clear previously-registered sources; got: \(advertised)")
    }
}
