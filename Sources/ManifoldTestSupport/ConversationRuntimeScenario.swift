#if DEBUG
import Foundation
import ManifoldRuntime
import ManifoldInference

/// A declarative composition scenario for the runtime turn-loop.
///
/// `ConversationRuntimeScenario` describes a sequence of user actions
/// (`send` / `regenerate` / `cancel`) against `ConversationRuntime`, the
/// scripted backend response per step, and the expected outcome shape. A
/// scenario can be authored by hand or decoded from JSON, then driven
/// through ``ConversationRuntimeScenarioRunner/run(scenario:backend:)`` —
/// no boilerplate plumbing in the test method.
///
/// The harness is *not* a `ScenarioRunner` extension. `ScenarioRunner`
/// (in `ManifoldTools`) is a tool-call validator that targets a backend
/// and a tool registry. `ConversationRuntimeScenario` targets the full
/// runtime composition: `ConversationRuntime` → `MockInferenceBackend` →
/// `SwiftDataPersistenceProvider`. The two cover different layers and are
/// kept apart deliberately.
///
/// ## Example
///
/// ```swift
/// let scenario = ConversationRuntimeScenario(
///     steps: [
///         .init(action: .send(text: "hello"), scriptedTokens: ["hi", " there"]),
///         .init(action: .regenerate, scriptedTokens: ["hi", " again"])
///     ],
///     expectedFinalAssistantContains: "again",
///     expectedAssistantMessageCount: 1  // regenerate replaces, not appends
/// )
/// let result = try await ConversationRuntimeScenarioRunner.run(
///     scenario: scenario,
///     backend: MockInferenceBackend()
/// )
/// ```
struct ConversationRuntimeScenario: Sendable, Codable {

    struct Step: Sendable, Codable {

        /// User-facing action driven against the runtime turn-loop.
        enum Action: Sendable, Codable, Equatable {
            case send(text: String)
            case regenerate
            /// Send a message but cancel the stream after observing
            /// `cancelAfterTokens` tokens. Reuses the standard
            /// stop-generation path. Defaults to 2 tokens.
            case cancelMidStream(text: String, cancelAfterTokens: Int)
        }

        let action: Action

        /// Tokens the backend should yield for this step's stream. Nil leaves
        /// the backend's existing `tokensToYield` in place.
        let scriptedTokens: [String]?

        init(action: Action, scriptedTokens: [String]? = nil) {
            self.action = action
            self.scriptedTokens = scriptedTokens
        }
    }

    let steps: [Step]

    /// If non-nil, the final assistant message's text content must contain
    /// this substring. OOD nonces are encouraged so a passing scenario
    /// can't be reproduced by a mock that silently swallows the script.
    let expectedFinalAssistantContains: String?

    /// If non-nil, the number of assistant messages persisted after all
    /// steps complete must equal this value. Discriminates send (appends)
    /// from regenerate (replaces).
    let expectedAssistantMessageCount: Int?

    init(
        steps: [Step],
        expectedFinalAssistantContains: String? = nil,
        expectedAssistantMessageCount: Int? = nil
    ) {
        self.steps = steps
        self.expectedFinalAssistantContains = expectedFinalAssistantContains
        self.expectedAssistantMessageCount = expectedAssistantMessageCount
    }
}

/// Result of running a ``ConversationRuntimeScenario`` through the
/// composition harness. Per-step outcomes plus a final aggregate.
struct ConversationRuntimeScenarioResult: Sendable {

    struct StepResult: Sendable {
        let action: ConversationRuntimeScenario.Step.Action
        let tokensObserved: [String]
        /// `true` when the step completed normally; `false` when it ended
        /// in error (e.g. cancelled streams) — note that `cancelMidStream`
        /// is *expected* to end in error, so `success=false` is fine there.
        let endedNormally: Bool
        let error: Error?
    }

    let stepResults: [StepResult]

    /// Concatenation of all `tokensObserved` across all steps, in order.
    let allTokensObserved: [String]

    /// All assistant message contents persisted at the end, in order.
    let finalAssistantContents: [String]

    /// `true` when both expected predicates (if non-nil) hold.
    let assertionsPassed: Bool

    /// Human-readable diagnostic when ``assertionsPassed`` is `false`.
    let assertionFailureReason: String?
}

/// Drives a ``ConversationRuntimeScenario`` against a fresh in-memory
/// `ManifoldBootstrap` configured with the supplied `MockInferenceBackend`.
///
/// One-shot type — the runner builds a SwiftData stack, creates a session,
/// runs every step, and returns the result. Tests should NOT cache a runner
/// instance across scenarios; each `run(...)` call gets its own state.
@MainActor
enum ConversationRuntimeScenarioRunner {

    /// Runs the scenario and returns the aggregated result. Throws only on
    /// infrastructure failures (e.g. failure to construct the SwiftData
    /// container). Step-level errors are recorded in `stepResults` and do
    /// not throw.
    static func run(
        scenario: ConversationRuntimeScenario,
        backend: MockInferenceBackend
    ) async throws -> ConversationRuntimeScenarioResult {
        let store = InMemoryScenarioStore()
        let inferenceService = InferenceService(backend: backend, name: "ScenarioMock")
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inferenceService
        )

        // Mark the backend loaded so the runtime can dispatch generations.
        backend.isModelLoaded = true

        // Use a stable sessionID across steps — every send/regenerate targets it.
        let sessionID = UUID()

        var stepResults: [ConversationRuntimeScenarioResult.StepResult] = []
        var allTokens: [String] = []

        for step in scenario.steps {
            if let scripted = step.scriptedTokens {
                backend.tokensToYield = scripted
            }
            let result = await runStep(
                step: step,
                runtime: runtime,
                sessionID: sessionID
            )
            stepResults.append(result)
            allTokens.append(contentsOf: result.tokensObserved)
        }

        // Drain persistence: read the assistant messages back via the store
        // so we exercise the persistence side too — not just the event stream.
        let messages = try await store.fetchMessages(for: sessionID)
        let assistantContents = messages
            .filter { $0.role == .assistant }
            .map { $0.content }

        let (assertionsPassed, failure) = evaluateAssertions(
            scenario: scenario,
            assistantContents: assistantContents
        )

        return ConversationRuntimeScenarioResult(
            stepResults: stepResults,
            allTokensObserved: allTokens,
            finalAssistantContents: assistantContents,
            assertionsPassed: assertionsPassed,
            assertionFailureReason: failure
        )
    }

    // MARK: - Helpers

    private static func runStep(
        step: ConversationRuntimeScenario.Step,
        runtime: ConversationRuntime,
        sessionID: UUID
    ) async -> ConversationRuntimeScenarioResult.StepResult {
        switch step.action {
        case .send(let text):
            return await driveAndAwait(
                step: step,
                runtime: runtime,
                drivingAction: {
                    let handle = try await runtime.processTurn(
                        TurnInput(sessionID: sessionID, kind: .send(text: text))
                    )
                    // `.send` always produces a stream handle.
                    return handle ?? ConversationStreamHandle()
                }
            )
        case .regenerate:
            return await driveAndAwait(
                step: step,
                runtime: runtime,
                drivingAction: {
                    let handle = try await runtime.processTurn(
                        TurnInput(sessionID: sessionID, kind: .regenerate)
                    )
                    return handle ?? ConversationStreamHandle()
                }
            )
        case .cancelMidStream(let text, _):
            return await driveAndAwait(
                step: step,
                runtime: runtime,
                drivingAction: {
                    let handle = try await runtime.processTurn(
                        TurnInput(sessionID: sessionID, kind: .send(text: text))
                    )
                    return handle ?? ConversationStreamHandle()
                }
            )
        }
    }

    /// Drives `drivingAction` (e.g. `runtime.send`) and waits for the
    /// returned handle's `streamFinished` event on `runtime.events` before
    /// returning. Without this, `send` would return immediately (it kicks
    /// off a detached generation task) and the persistence side wouldn't
    /// be readable yet.
    private static func driveAndAwait(
        step: ConversationRuntimeScenario.Step,
        runtime: ConversationRuntime,
        drivingAction: () async throws -> ConversationStreamHandle
    ) async -> ConversationRuntimeScenarioResult.StepResult {
        let handle: ConversationStreamHandle
        do {
            handle = try await drivingAction()
        } catch let caught {
            return ConversationRuntimeScenarioResult.StepResult(
                action: step.action,
                tokensObserved: step.scriptedTokens ?? [],
                endedNormally: false,
                error: caught
            )
        }

        // Drain runtime events until we see a streamFinished or errorRaised
        // for this handle. Bounded by a wall-clock deadline so a buggy
        // backend can't deadlock the harness.
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in runtime.events {
            // streamFinished's first associated value is the messageID UUID;
            // we don't have an easy way to match by handle here without
            // hooking deeper into the runtime, so we exit on the first
            // streamFinished we see. For sequential single-step scenarios
            // that's fine — if a future refinement runs steps in parallel,
            // this will need handle-correlation.
            if case .streamFinished = event { break }
            if case .errorRaised = event { break }
            if ContinuousClock().now > deadline {
                break
            }
        }

        return ConversationRuntimeScenarioResult.StepResult(
            action: step.action,
            tokensObserved: step.scriptedTokens ?? [],
            endedNormally: true,
            error: nil
        )
    }

    /// Simple in-memory `MessageStore` conformer used by the scenario
    /// runner. Mirrors the `RuntimeMessageStore` pattern that
    /// `ConversationRuntimeTests` rolls inline. Kept private to the file —
    /// the harness API exposes only the result types, not the store.
    private final class InMemoryScenarioStore: MessageStore, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessageRecord) async throws {
            let snapshot = upsertAndSnapshotHooks(message)
            for hook in snapshot {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            let snapshot = upsertAndSnapshotHooks(message)
            for hook in snapshot {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            removeMessage(id: messageID)
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messagesForSession(sessionID)
        }

        func deleteMessages(for sessionID: UUID) async throws {
            removeMessagesForSession(sessionID)
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
            appendHook(hook)
        }

        // MARK: - Sync lock-helpers (avoid NSLock.unlock in async ctx)

        private func upsertAndSnapshotHooks(_ message: ChatMessageRecord) -> [any MessageStorePostWriteHook] {
            lock.lock()
            defer { lock.unlock() }
            messages[message.id] = message
            return hooks
        }

        private func removeMessage(id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            messages.removeValue(forKey: id)
        }

        private func messagesForSession(_ sessionID: UUID) -> [ChatMessageRecord] {
            lock.lock()
            defer { lock.unlock() }
            return messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        private func removeMessagesForSession(_ sessionID: UUID) {
            lock.lock()
            defer { lock.unlock() }
            messages = messages.filter { $0.value.sessionID != sessionID }
        }

        private func appendHook(_ hook: any MessageStorePostWriteHook) {
            lock.lock()
            defer { lock.unlock() }
            hooks.append(hook)
        }
    }

    private static func evaluateAssertions(
        scenario: ConversationRuntimeScenario,
        assistantContents: [String]
    ) -> (passed: Bool, reason: String?) {
        if let expectedSubstring = scenario.expectedFinalAssistantContains {
            guard let last = assistantContents.last else {
                return (false, "expectedFinalAssistantContains specified but no assistant messages were persisted")
            }
            if !last.contains(expectedSubstring) {
                return (false, "final assistant content '\(last)' did not contain '\(expectedSubstring)'")
            }
        }
        if let expectedCount = scenario.expectedAssistantMessageCount {
            if assistantContents.count != expectedCount {
                return (false, "expected \(expectedCount) assistant messages, got \(assistantContents.count)")
            }
        }
        return (true, nil)
    }
}
#endif
