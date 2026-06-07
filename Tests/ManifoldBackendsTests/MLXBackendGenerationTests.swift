#if MLX
import XCTest
import MLXLMCommon
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

// Conform MockMLXModelContainer to the internal protocol in this test target,
// where both the internal protocol and the public mock type are visible.
extension MockMLXModelContainer: MLXModelContainerProtocol {
    func prepare(messages: [[String : String]]) async throws -> MLXPreparedInput {
        let promptTokenIds = try await prepareForGeneration(messages: messages)
        return MLXPreparedInput(promptTokenIds: promptTokenIds)
    }

    func prepare(chat: SendableChatMessages) async throws -> MLXPreparedInput {
        let promptTokenIds = try await prepareForGeneration(chat: chat.value)
        return MLXPreparedInput(promptTokenIds: promptTokenIds)
    }

    func makeCache(parameters: GenerateParameters) async throws -> MLXPromptCache {
        MLXPromptCache(makeCacheForGeneration(parameters: parameters))
    }

    func generate(
        input: MLXPreparedInput,
        cache: MLXPromptCache?,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        try await generatePreparedInput(
            promptTokenIds: input.promptTokenIds,
            cache: cache.map { SendableKVCacheList($0.value) },
            parameters: parameters
        )
    }
}

/// Unit tests for `MLXBackend.generate()` using `MockMLXModelContainer`.
///
/// These tests run in CI without Apple Silicon — the generation path is driven
/// entirely by the injected mock which never touches the Metal GPU stack.
/// `test_sendableLMInput_wrapsAndUnwraps` is limited to compile-time/type-level
/// wrapping checks and does not perform an MLX/Metal runtime round trip.
final class MLXBackendGenerationTests: XCTestCase {

    // MARK: - Helpers

    /// Drains all `.token` events from a `GenerationStream` into an ordered array.
    private func collectTokens(
        from stream: GenerationStream
    ) async throws -> [String] {
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }
        return tokens
    }

    private final class YieldCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }

    // MARK: - test_generate_yieldsInjectedTokens

    func test_generate_yieldsInjectedTokens() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["Hello", " world"]

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let tokens = try await collectTokens(from: stream)

        XCTAssertEqual(tokens, ["Hello", " world"],
            "Stream must yield exactly the injected tokens in order")
        XCTAssertEqual(mock.generateCallCount, 1)

        // Verify the messages were assembled with user role.
        XCTAssertEqual(mock.lastMessages?.last?["role"], "user")
        XCTAssertEqual(mock.lastMessages?.last?["content"], "hi")

        // Sabotage check: tokensToYield = [] would produce an empty array,
        // failing the equality assertion.
    }

    // MARK: - test_generate_respectsMaxOutputTokens

    func test_generate_respectsMaxOutputTokens() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]

        let backend = MLXBackend()
        backend._inject(mock)

        var config = GenerationConfig()
        config.maxOutputTokens = 3

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )

        let tokens = try await collectTokens(from: stream)

        XCTAssertEqual(tokens.count, 3,
            "Backend must stop yielding after maxOutputTokens tokens")
        XCTAssertEqual(tokens, ["A", "B", "C"])

        // Sabotage check: setting maxOutputTokens = 100 yields all 10 tokens,
        // causing the count assertion to fail.
    }

    func test_generate_withVisionHistory_preparesStructuredChat() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["seen"]

        let backend = MLXBackend()
        backend._inject(mock, supportsVision: true)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Describe this image."),
                .image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png"),
            ])
        ])

        let stream = try backend.generate(
            prompt: "fallback",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let tokens = try await collectTokens(from: stream)

        XCTAssertEqual(tokens, ["seen"])
        XCTAssertEqual(mock.lastChatMessages?.count, 1)
        XCTAssertEqual(mock.lastChatMessages?.first?.content, "Describe this image.")
        XCTAssertEqual(mock.lastChatMessages?.first?.images.count, 1)
        XCTAssertNil(mock.lastMessages, "Vision turns should go through UserInput(chat:) instead of text-only message dictionaries")
    }

    func test_generate_toolAwareVisionHistory_preservesOriginalImages() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]

        let backend = MLXBackend()
        backend._inject(mock, supportsVision: true, dialect: .qwen25)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Please inspect this chart."),
                .image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png"),
            ])
        ])
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "Please inspect this chart."),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [
                    ToolCall(id: "call_1", toolName: "summarize_image", arguments: "{}")
                ]
            ),
        ])

        _ = try await collectTokens(from: try backend.generate(
            prompt: "fallback",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        XCTAssertEqual(mock.lastChatMessages?.count, 2)
        XCTAssertEqual(mock.lastChatMessages?.first?.images.count, 1)
        XCTAssertTrue(
            mock.lastChatMessages?[1].content.contains("<tool_call>") == true,
            "Tool-aware vision turns must keep the serialized tool call content while preserving the earlier image"
        )
    }

    func test_generate_withVisionHistory_andSystemPrompt_prependsSystemChatMessage() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["seen"]

        let backend = MLXBackend()
        backend._inject(mock, supportsVision: true)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Describe this image."),
                .image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png"),
            ])
        ])

        _ = try await collectTokens(from: try backend.generate(
            prompt: "fallback",
            systemPrompt: "You are a precise image analyst.",
            config: GenerationConfig()
        ))

        XCTAssertEqual(mock.lastChatMessages?.count, 2)
        XCTAssertEqual(mock.lastChatMessages?.first?.content, "You are a precise image analyst.")
        XCTAssertEqual(mock.lastChatMessages?.first?.images.count, 0)
        XCTAssertEqual(mock.lastChatMessages?[1].images.count, 1)
    }

    func test_generate_reusesPromptCachePrefixOnMatchingTurn() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [11, 12, 13, 14],
            [11, 12, 13, 14, 15],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let secondStream = try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let secondEvents = try await collectAllEvents(from: secondStream)
        let reuseCounts = secondEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertEqual(reuseCounts, [4],
            "Second turn should emit kvCacheReuse for the shared 4-token prompt prefix")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [4],
            "Generation should resume from the restored prefix length, not from a cold cache")

        // Sabotage check: disabling enableKVCacheReuse or clearing _promptCacheSnapshot
        // before the second turn makes reuseCounts empty and the cache offset 0.
    }

    func test_generate_withReuseDisabled_doesNotPersistPromptSnapshot() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [[16, 17, 18, 19]]

        let backend = MLXBackend(enableKVCacheReuse: false)
        backend._inject(mock)

        XCTAssertFalse(backend._hasPromptCacheSnapshotForTesting())
        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        XCTAssertFalse(
            backend._hasPromptCacheSnapshotForTesting(),
            "Default-off reuse must not retain prompt-cache state between turns"
        )

        // Sabotage check: capturing snapshots unconditionally leaves a retained
        // prompt snapshot here and fails the final assertion.
    }

    func test_generate_reusesOnlySharedPrefixAfterPromptDivergence() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [21, 22, 23, 24],
            [21, 22, 99, 100],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let secondEvents = try await collectAllEvents(from: try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        let reuseCounts = secondEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertEqual(reuseCounts, [2],
            "Only the shared head of the prompt should be reused after divergence")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [2],
            "Restored cache should be trimmed to the shared-prefix length before generation")

        // Sabotage check: changing the second prepared token batch to start with
        // [21, 99, ...] drops reuse to 1 and fails the assertions.
    }

    func test_generate_unsupportedCacheShapeBypassesReuseAndClearsSnapshot() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [31, 32, 33, 34],
            [31, 32, 33, 34, 35],
            [31, 32, 33, 34, 35, 36],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        mock.cacheFactory = { [RotatingKVCache(maxSize: 32)] }
        let secondEvents = try await collectAllEvents(from: try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        let secondReuseCounts = secondEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertTrue(secondReuseCounts.isEmpty,
            "Unsupported cache families must bypass prompt-cache restore")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [0],
            "Unsupported cache families should start from a cold cache")

        mock.cacheFactory = { [KVCacheSimple()] }
        let thirdEvents = try await collectAllEvents(from: try backend.generate(
            prompt: "third",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        let thirdReuseCounts = thirdEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertTrue(thirdReuseCounts.isEmpty,
            "A turn that bypasses reuse must clear the prior snapshot rather than keeping stale state")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [0],
            "After an unsupported turn the next request should still begin cold")

        // Sabotage check: if unsupported caches leave the old snapshot intact, the
        // third turn reuses 4+ tokens and both assertions fail.
    }

    func test_resetConversation_invalidatesPromptCache() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [41, 42, 43, 44],
            [41, 42, 43, 44, 45],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        backend.resetConversation()

        let secondEvents = try await collectAllEvents(from: try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        let reuseCounts = secondEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertTrue(reuseCounts.isEmpty,
            "resetConversation must invalidate any cached prompt prefix")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [0],
            "After resetConversation the next turn should start from a cold cache")

        // Sabotage check: removing the resetConversation() call restores a 4-token hit.
    }

    func test_generate_offsetOnlyMockRestoresPromptLengthAfterPriorCompletionTail() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.simulatedCacheCompletionTokenCount = 3
        mock.preparedTokenBatches = [
            [51, 52, 53, 54],
            [51, 52, 53, 54, 55],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await collectAllEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let secondEvents = try await collectAllEvents(from: try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        let reuseCounts = secondEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }

        XCTAssertEqual(reuseCounts, [4],
            "Only prompt tokens, not the simulated completion tail, should be restorable on the next turn")
        XCTAssertEqual(mock.lastInitialCacheOffsets, [4],
            "Even on the offset-only mock path, restore should clamp back to the prompt length before reuse")

        // Sabotage check: if the restore path keeps the simulated 3-token completion
        // tail, lastInitialCacheOffsets becomes 7 and fails this assertion. The
        // real tensor-state trim/copy path is covered by the Xcode-only MLX
        // integration suite, not this CI-safe mock.
    }

    // MARK: - test_generate_cancellation

    func test_generate_cancellation() async throws {
        let mock = MockMLXModelContainer()
        // Use many tokens so the stream is still live when we cancel.
        mock.tokensToYield = Array(repeating: "x", count: 50)

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Consume one token, then break to cancel the stream.
        var receivedCount = 0
        for try await event in stream.events {
            if case .token = event {
                receivedCount += 1
                if receivedCount == 1 { break }
            }
        }

        // The stream's onTermination fires task.cancel() which sets isGenerating = false
        // asynchronously in the @MainActor task. Poll with a tight deadline.
        let expectation = expectation(description: "isGenerating clears after cancel")
        Task {
            let deadline = ContinuousClock.now + .seconds(2)
            while backend.isGenerating, ContinuousClock.now < deadline {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 3)

        XCTAssertFalse(backend.isGenerating,
            "isGenerating must be false after the stream is cancelled")
        XCTAssertEqual(receivedCount, 1,
            "Should have consumed exactly one token before cancelling")

        // Sabotage check: removing the break would drain the full stream, making
        // isGenerating false for the wrong reason (completion, not cancellation).
    }

    // MARK: - test_generate_generateThrows_propagatesError

    func test_generate_generateThrows_propagatesError() async throws {
        struct GenerateFailure: Error {}

        let mock = MockMLXModelContainer()
        mock.generateError = GenerateFailure()

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Drain the stream — the thrown error surfaces via the events stream.
        var didThrow = false
        do {
            for try await _ in stream.events {}
        } catch {
            didThrow = true
            XCTAssertTrue(error is GenerateFailure, "Expected GenerateFailure, got \(error)")
        }

        XCTAssertTrue(didThrow, "Stream must propagate the error thrown by generate")

        // Verify the GenerationStream reached the .failed phase.
        let phase = await MainActor.run { stream.phase }
        if case .failed = phase {
            // Expected.
        } else {
            XCTFail("Expected stream phase .failed, got \(phase)")
        }

        // Sabotage check: removing mock.generateError leaves generateError as nil,
        // so the stream succeeds and didThrow stays false, failing the assertion.
    }

    // MARK: - test_sendableLMInput_wrapsAndUnwraps

    // MARK: - Stop reason surfacing (#515)

    /// Helper: drains every event (token, thinking, usage, tool-call) into an ordered array.
    private func collectAllEvents(
        from stream: GenerationStream
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Documents today's conflation: both natural end-of-stream AND `maxOutputTokens`
    /// cutoff collapse to `GenerationStream.Phase.done` with no dedicated
    /// "stop_reason" signal. Downstream UI that wants to render "response truncated"
    /// today has nothing to key off.
    ///
    /// The fixture drives both paths in a single test so the shared baseline assertion
    /// ("all terminations look identical today") is written once. When structured
    /// stop reasons land (GenerationEvent.stopReason(.endOfStream / .maxTokens)), flip
    /// the per-branch assertions to the target shape — see FIXMEs inline.
    func test_stopReason_currentlyCollapsesToDone_forBothNaturalAndMaxTokens() async throws {
        // MARK: Natural EOS — mock finishes its finite token list
        do {
            let mock = MockMLXModelContainer()
            mock.tokensToYield = ["Hi", "."]

            let backend = MLXBackend()
            backend._inject(mock)

            let stream = try backend.generate(
                prompt: "hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )

            let events = try await collectAllEvents(from: stream)
            let tokens = events.compactMap { ev -> String? in
                if case .token(let t) = ev { return t } else { return nil }
            }
            XCTAssertEqual(tokens, ["Hi", "."],
                "Natural EOS must surface every injected token before termination")

            // GenerationEvent has no stopReason case — Claude/MLX stop reasons are not surfaced. Documents the current gap.
            let phase = await MainActor.run { stream.phase }
            if case .done = phase {
                // Expected today.
            } else {
                XCTFail("Expected .done phase on natural EOS, got \(phase)")
            }
        }

        // MARK: Hit maxOutputTokens — same .done phase, no structured distinction
        do {
            let mock = MockMLXModelContainer()
            mock.tokensToYield = Array(repeating: "x", count: 50)

            let backend = MLXBackend()
            backend._inject(mock)

            var config = GenerationConfig()
            config.maxOutputTokens = 3

            let stream = try backend.generate(
                prompt: "hi",
                systemPrompt: nil,
                config: config
            )

            let events = try await collectAllEvents(from: stream)
            let tokens = events.compactMap { ev -> String? in
                if case .token(let t) = ev { return t } else { return nil }
            }
            XCTAssertEqual(tokens.count, 3,
                "maxOutputTokens must cap visible tokens — this is the truncation the UI cares about")

            // GenerationEvent has no stopReason case — Claude/MLX stop reasons are not surfaced. Documents the current gap.
            let phase = await MainActor.run { stream.phase }
            if case .done = phase {
                // Expected today — the conflation this fixture exists to flag.
            } else {
                XCTFail("Expected .done phase on maxOutputTokens cutoff, got \(phase)")
            }
        }

        // Sabotage check: changing the first mock.tokensToYield to ["Hi"] makes the
        // natural-EOS branch's XCTAssertEqual(tokens, ["Hi", "."]) fail. Raising the
        // second branch's maxOutputTokens to 100 breaks the tokens.count == 3 check.
    }

    // MARK: - Tool call extraction (#517 — shipped)

    /// MLX now extracts tool calls from the stream (#517). Extraction is
    /// whole-call by design: `MLXBackend` wires `ToolCallTransform` with
    /// `MLXToolMarkers.markers()` into the driver pipeline and emits a single
    /// `.toolCall` event per `<tool_call>…</tool_call>` block — there is no
    /// per-token delta event. The transform stage only activates when the call
    /// passes tools AND the model speaks a known dialect, so this drives the
    /// full `generate` → `MLXGenerationDriver` path (not just the transform unit,
    /// which `MLXToolMarkersParityTests` covers separately).
    ///
    /// Runs on the injected mock container — no Metal, consistent with the other
    /// tests in this suite.
    func test_toolCall_extractedFromStream_wholeCall() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = [
            "<tool_call>",
            "{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}",
            "</tool_call>",
        ]

        let backend = MLXBackend()
        // A known dialect is required for the tool stage to activate.
        backend._inject(mock, dialect: .qwen25)

        var config = GenerationConfig()
        config.tools = [
            ToolDefinition(name: "get_weather", description: "weather", parameters: .object([:]))
        ]

        let stream = try backend.generate(
            prompt: "weather?",
            systemPrompt: nil,
            config: config
        )

        let events = try await collectAllEvents(from: stream)

        let visibleTokens = events.compactMap { ev -> String? in
            if case .token(let t) = ev { return t } else { return nil }
        }
        XCTAssertFalse(visibleTokens.joined().contains("<tool_call>"),
            "tool_call tags must not leak into visible .token output")

        let extractedNames = events.compactMap { ev -> String? in
            if case .toolCall(let call) = ev { return call.toolName } else { return nil }
        }
        XCTAssertEqual(extractedNames, ["get_weather"],
            "A single whole-call .toolCall event naming get_weather must surface")

        // Sabotage check: removing the tool stage in MLXGenerationDriver makes the
        // raw `<tool_call>` bytes leak back into .token events, failing both asserts.
    }

    // MARK: - Chat-template detection (#516)

    /// Covers the observable slice of MLX chat-template handling: the `messages`
    /// dictionary array the backend hands to the container, unchanged.
    ///
    /// The full detection matrix (missing `tokenizer_config.json`, template without an
    /// `<|assistant|>` marker) is now driven via `simulatedTokenizerApplyFailure`
    /// on the mock container — see the two sibling tests below.
    func test_chatTemplate_messagesPassThroughUnchanged() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]

        let backend = MLXBackend()
        backend._inject(mock)

        let systemPrompt = "You are helpful."
        let userPrompt = "hello"

        let stream = try backend.generate(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            config: GenerationConfig()
        )

        // Drain so the generate task completes and `lastMessages` is populated.
        _ = try await collectAllEvents(from: stream)

        // The backend hands the MLX container the [role:system, role:user] pair so the
        // real tokenizer's chat template can apply. A template missing `<|assistant|>`
        // will fail at tokenize time, not here — that branch is covered by the sibling
        // skip test below plus #551.
        let sent = try XCTUnwrap(mock.lastMessages,
            "MLXBackend.generate must pass a messages array to the container")
        XCTAssertEqual(sent.count, 2,
            "Expected [system, user] when both prompts are provided")
        XCTAssertEqual(sent.first?["role"], "system")
        XCTAssertEqual(sent.first?["content"], systemPrompt)
        XCTAssertEqual(sent.last?["role"], "user")
        XCTAssertEqual(sent.last?["content"], userPrompt)

        // Sabotage check: reordering the msgs.append calls in MLXBackend.generate would
        // flip system and user positions, failing the first/last XCTAssertEquals.
    }

    // MARK: - test_chatTemplate_missingTemplate_throwsModelLoadFailed

    /// When the loaded tokenizer has no `chat_template` (e.g. `tokenizer_config.json`
    /// missing the field, or the file itself absent in the model snapshot), the
    /// MLX container raises an error from `apply_chat_template` *during generation*.
    ///
    /// Today `MLXBackend` does NOT wrap that error in `InferenceError.modelLoadFailed`
    /// — `modelLoadFailed` is reserved for the `loadModel(...)` path. The error
    /// surfaces unchanged through the GenerationStream's `try await events`. This
    /// test pins the current behavior so the failure mode is visible and a future
    /// structured-error change has a concrete fixture to update.
    func test_chatTemplate_missingTemplate_throwsModelLoadFailed() async throws {
        struct MissingChatTemplateError: Error, Equatable {
            let detail = "tokenizer_config.json missing chat_template field"
        }

        let mock = MockMLXModelContainer()
        mock.simulatedTokenizerApplyFailure = MissingChatTemplateError()
        mock.simulatedChatTemplate = nil // documents the scenario

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: "You are helpful.",
            config: GenerationConfig()
        )

        var caught: Error?
        do {
            for try await _ in stream.events {}
        } catch {
            caught = error
        }

        let unwrapped = try XCTUnwrap(caught,
            "Stream must surface the tokenizer-apply error rather than completing silently")
        // Today MLXBackend does not wrap mid-generation errors in `modelLoadFailed`;
        // the underlying error propagates as-is. If a future change wraps these
        // errors structurally, flip this assertion to match.
        XCTAssertTrue(unwrapped is MissingChatTemplateError,
            "Expected MissingChatTemplateError to propagate unchanged, got \(type(of: unwrapped))")

        // Phase must be .failed so observers can react to the error.
        let phase = await MainActor.run { stream.phase }
        if case .failed = phase {
            // Expected.
        } else {
            XCTFail("Expected stream phase .failed, got \(phase)")
        }

        // Sabotage check: clearing simulatedTokenizerApplyFailure makes the stream
        // succeed and `caught` stays nil, failing the XCTUnwrap.
    }

    // MARK: - test_chatTemplate_noAssistantMarker_throwsStructuredError

    /// When the chat template is present but malformed (e.g. it never emits an
    /// `<|assistant|>` marker so the tokenizer has nowhere to start the model's
    /// turn), `apply_chat_template` raises a different error class. Same surfacing
    /// contract — propagated unchanged through the GenerationStream.
    func test_chatTemplate_noAssistantMarker_throwsStructuredError() async throws {
        struct NoAssistantMarkerError: Error, Equatable {
            let detail = "chat template missing <|assistant|> marker"
        }

        let mock = MockMLXModelContainer()
        mock.simulatedTokenizerApplyFailure = NoAssistantMarkerError()
        // Document the malformed template the test is exercising.
        mock.simulatedChatTemplate = "{% for message in messages %}{{ message.content }}{% endfor %}"

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var caught: Error?
        do {
            for try await _ in stream.events {}
        } catch {
            caught = error
        }

        let unwrapped = try XCTUnwrap(caught,
            "Stream must surface the malformed-template error")
        XCTAssertTrue(unwrapped is NoAssistantMarkerError,
            "Expected NoAssistantMarkerError to propagate unchanged, got \(type(of: unwrapped))")

        // The mock must have observed the call before throwing — confirms the
        // backend reached the container's generate path before the apply failed.
        XCTAssertEqual(mock.generateCallCount, 1)
        XCTAssertEqual(mock.lastMessages?.last?["role"], "user")

        // Sabotage check: setting mock.simulatedTokenizerApplyFailure = nil lets
        // the stream complete with the default tokens, leaving `caught` nil and
        // failing the XCTUnwrap.
    }

    // MARK: - test_generate_usesConversationHistory

    func test_generate_usesConversationHistory() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]

        let backend = MLXBackend()
        backend._inject(mock)

        // Simulate two prior turns before the current user message.
        backend.setConversationHistory([
            ("user", "What is the capital of France?"),
            ("assistant", "Paris."),
            ("user", "And Germany?"),
        ])

        let stream = try backend.generate(
            prompt: "And Germany?",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        _ = try await collectTokens(from: stream)

        let sent = try XCTUnwrap(mock.lastMessages)
        XCTAssertEqual(sent.count, 3,
            "All three history turns must be forwarded to the container")
        XCTAssertEqual(sent[0]["role"], "user")
        XCTAssertEqual(sent[0]["content"], "What is the capital of France?")
        XCTAssertEqual(sent[1]["role"], "assistant")
        XCTAssertEqual(sent[1]["content"], "Paris.")
        XCTAssertEqual(sent[2]["role"], "user")
        XCTAssertEqual(sent[2]["content"], "And Germany?")

        // Sabotage check: removing the setConversationHistory call causes the
        // backend to fall back to the bare prompt path, producing a 1-element
        // messages array and failing the count assertion.
    }

    // MARK: - WindowServer yield cadence (#747)

    /// Asserts the cooperative yield inserted to prevent WindowServer GPU-queue
    /// starvation fires every `yieldEveryNTokens` MLX-emitted chunks. We replace
    /// the production `Task.yield()` with a counting hook
    /// so the test is deterministic and free of timing assumptions. Setting
    /// `yieldEveryNTokens = 0` must disable the yield entirely.
    ///
    /// `#if MLX` plus the existing mock-container path keep this test running
    /// in CI without Metal — the production code path is identical, the test
    /// just substitutes the sleep with a counter.
    func test_yieldEveryNTokens_firesAtConfiguredCadence() async throws {
        let counter = YieldCounter()
        MLXBackend._yieldHookForTesting = { counter.increment() }
        defer { MLXBackend._yieldHookForTesting = nil }

        // Configured cadence: every 4 chunks. With 12 chunks emitted we expect
        // exactly 3 yields (at 4, 8, 12). maxOutputTokens is set high enough
        // that the limit doesn't truncate before the full chunk count.
        let mock = MockMLXModelContainer()
        mock.tokensToYield = Array(repeating: "x", count: 12)

        let backend = MLXBackend()
        backend._inject(mock)

        var config = GenerationConfig()
        config.yieldEveryNTokens = 4
        config.maxOutputTokens = 100

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )
        _ = try await collectTokens(from: stream)

        XCTAssertEqual(counter.count, 3,
            "Yield must fire exactly every yieldEveryNTokens chunks (12 / 4 = 3)")

        // Now verify yieldEveryNTokens = 0 disables the yield entirely.
        let counter2 = YieldCounter()
        MLXBackend._yieldHookForTesting = { counter2.increment() }

        let mock2 = MockMLXModelContainer()
        mock2.tokensToYield = Array(repeating: "x", count: 12)

        let backend2 = MLXBackend()
        backend2._inject(mock2)

        var disabledConfig = GenerationConfig()
        disabledConfig.yieldEveryNTokens = 0
        disabledConfig.maxOutputTokens = 100

        let stream2 = try backend2.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: disabledConfig
        )
        _ = try await collectTokens(from: stream2)

        XCTAssertEqual(counter2.count, 0,
            "yieldEveryNTokens = 0 must skip the cooperative yield entirely")

        // Sabotage check: changing the modulo condition to `% (yieldEvery + 1)`
        // in MLXBackend would yield 2 times for 12 chunks at cadence 4 (at 5, 10),
        // failing the count == 3 assertion.
    }

    func test_yieldEveryNTokens_defaultCadenceIsEight() async throws {
        let counter = YieldCounter()
        MLXBackend._yieldHookForTesting = { counter.increment() }
        defer { MLXBackend._yieldHookForTesting = nil }

        let mock = MockMLXModelContainer()
        mock.tokensToYield = Array(repeating: "x", count: 16)

        let backend = MLXBackend()
        backend._inject(mock)

        var config = GenerationConfig()
        config.maxOutputTokens = 100

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )
        _ = try await collectTokens(from: stream)

        XCTAssertEqual(counter.count, 2,
            "Default MLX yield cadence should fire every 8 emitted chunks")

        // Sabotage check: changing GenerationConfig's default yieldEveryNTokens
        // away from 8 changes the number of hook invocations for 16 chunks.
    }

    /// Cancellation during the cooperative yield must not crash, must not leak
    /// `CancellationError` to the consumer (the production sleep is `try?`'d),
    /// and the next loop iteration's `Task.isCancelled` check must terminate
    /// the stream cleanly.
    ///
    /// The hook substitutes for `Task.yield()`, so to model "cancellation while
    /// yielding" we cancel the surrounding generation Task from inside the hook
    /// itself — this exercises the same control-flow shape as a real cancel
    /// arriving at a cooperative yield point.
    func test_yieldEveryNTokens_cancellationDuringYield_terminatesCleanly() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = Array(repeating: "x", count: 32)

        let backend = MLXBackend()
        backend._inject(mock)

        // Cancel mid-generation from inside the yield hook. By the time the
        // first yield fires (at chunk 4) we cancel via stopGeneration(), which
        // cancels the underlying generation Task. The next iteration of the
        // mlxStream `for await` should observe `Task.isCancelled` and break.
        MLXBackend._yieldHookForTesting = { [weak backend] in
            backend?.stopGeneration()
        }
        defer { MLXBackend._yieldHookForTesting = nil }

        var config = GenerationConfig()
        config.yieldEveryNTokens = 4
        config.maxOutputTokens = 100

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )

        // Drain the stream — must complete without throwing, even though the
        // surrounding task was cancelled mid-yield. The yield hook does not throw,
        // matching production `Task.yield()`, so the for-await observes
        // cancellation at the top of the next iteration.
        let tokens = try await collectTokens(from: stream)

        // Expect at most ~yieldEvery tokens to have been emitted before the
        // cancel propagated. Strictly: no more than one full cadence past the
        // cancel point. The point of the assertion is simply that we exited
        // cleanly and didn't drain all 32 tokens.
        XCTAssertLessThan(tokens.count, 32,
            "Cancellation during yield must terminate the stream early")
    }

    func test_sendableLMInput_wrapsAndUnwraps() throws {
        // This test verifies `SendableLMInput` at the type level: the wrapper must
        // satisfy Swift's `Sendable` requirement so the compiler allows cross-actor
        // transfer. The MLX runtime (Metal) is NOT accessed here.
        //
        // Full round-trip testing (with a real LMInput) requires Metal and is
        // exercised in ManifoldE2ETests on Apple Silicon hardware.

        // Verify that SendableLMInput is Sendable at compile time.
        // If the @unchecked Sendable annotation were removed, the compiler would
        // reject the line below with a Sendable violation.
        func assertSendable<T: Sendable>(_: T.Type) {}
        assertSendable(SendableLMInput.self)

        // Verify the wrapper's public surface at compile time without constructing
        // an LMInput: both the initializer and `.value` must be accessible.
        let initializer = SendableLMInput.init
        let valueKeyPath = \SendableLMInput.value
        _ = (initializer, valueKeyPath)
    }
}
#endif
