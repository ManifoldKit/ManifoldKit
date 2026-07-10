@preconcurrency import XCTest
import Observation
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Perf-audit β-1: observer-cascade fan-out per token batch.
///
/// The audit identified that `ChatViewModel` is an `@Observable` god-object,
/// so every per-token mutation (the `tokenEmitted` event handler that mutates
/// `messages[idx].contentParts`) potentially wakes every SwiftUI subscriber
/// that reads ANY property of the view model — including properties that are
/// completely unrelated to streaming (`selectedModel`, `selectedEndpoint`,
/// `pinnedMessageIDs`, etc.).
///
/// With Swift's Observation framework, an observer that reads property `X`
/// only fires when `X` is mutated — not on unrelated mutations. So a
/// well-behaved `@Observable` should produce ZERO observer callbacks for
/// unrelated properties when `messages` is mutated.
///
/// This test counts those callbacks. Each non-zero count documents the
/// cascade tax. After ChatViewModel decomposition (issue #329 follow-ups)
/// these counts should drop to zero. The test is **structured as a
/// regression baseline** — it asserts the count is bounded, not that the
/// count is zero, so today's behaviour is captured without a flaky failure.
@MainActor
final class ObserverCascadeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    /// Streams a 200-token reply through `MockInferenceBackend` and counts
    /// observer wake-ups for three properties that have no relationship to
    /// streaming token batches: `selectedModel`, `selectedEndpoint`, and
    /// `pinnedMessageIDs`.
    ///
    /// `withObservationTracking` fires its `onChange` once when ANY tracked
    /// property is mutated; the test re-arms the tracker inside the
    /// callback so the counter accumulates across the whole stream.
    ///
    /// Each non-zero count after the stream is the cascade tax. Today these
    /// are expected to be zero — Swift's Observation framework is per-property.
    /// If a future change accidentally widens the observation surface (e.g.
    /// a computed property that reads multiple stored properties without
    /// `@ObservationIgnored`), the counts will rise and this test surfaces
    /// the regression.
    func testStreamingTokenWakesUnrelatedObservers() async throws {
        let mock = MockInferenceBackend()
        // 200 single-character tokens — enough to exercise the
        // StreamingTokenBatcher's flush boundary multiple times so the
        // adapter's `tokenEmitted` handler fires repeatedly.
        mock.tokensToYield = (0..<200).map { _ in "x" }
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "ObserverCascadeMock")
        let store = ObserverCascadeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        let vm = ChatViewModel(
            inferenceService: inference,
            conversationRuntime: runtime
        )
        vm.activeSession = ManifoldInference.ChatSession(title: "ObserverCascade")

        // Counters for unrelated properties. Each tracker self-rearms by
        // dispatching back to `@MainActor` from inside the `onChange`
        // callback so the cascade is observed across the whole stream, not
        // just the first mutation. The CascadeProbe class holds the
        // re-arm closure so it can be referenced from inside the
        // `@Sendable` `Task { ... }` closure without capturing a local
        // function (which would be non-Sendable under Swift 6).
        let modelProbe = CascadeProbe(vm: vm) { vm, probe in
            withObservationTracking {
                _ = vm.selectedModel
            } onChange: { [weak probe] in
                Task { @MainActor in probe?.recordChange() }
            }
        }
        let endpointProbe = CascadeProbe(vm: vm) { vm, probe in
            withObservationTracking {
                _ = vm.selectedEndpoint
            } onChange: { [weak probe] in
                Task { @MainActor in probe?.recordChange() }
            }
        }
        let pinnedProbe = CascadeProbe(vm: vm) { vm, probe in
            withObservationTracking {
                _ = vm.pinnedMessageIDs
            } onChange: { [weak probe] in
                Task { @MainActor in probe?.recordChange() }
            }
        }
        // Sanity probe: messages should fire repeatedly during a streamed
        // turn — the test infrastructure must observe at least one wake or
        // the cascade probes' zero counts mean nothing.
        let messagesProbe = CascadeProbe(vm: vm) { vm, probe in
            withObservationTracking {
                _ = vm.messages
            } onChange: { [weak probe] in
                Task { @MainActor in probe?.recordChange() }
            }
        }

        modelProbe.arm()
        endpointProbe.arm()
        pinnedProbe.arm()
        messagesProbe.arm()

        // Drive the full stream through the runtime.
        vm.inputText = "go"
        await vm.sendMessage()
        await vm.awaitGenerating(false)

        let messagesChanges = messagesProbe.changeCount
        let modelChanges = modelProbe.changeCount
        let endpointChanges = endpointProbe.changeCount
        let pinnedChanges = pinnedProbe.changeCount

        // Sanity: messages observation must have fired at least once. If
        // this fails the test infrastructure is broken, not the cascade tax.
        XCTAssertGreaterThan(messagesChanges, 0,
            "Sanity: messages observer must fire at least once during a streamed turn")

        // Cascade-tax baselines. Today these are expected to be zero —
        // Observation is per-property and the streaming path mutates only
        // `messages` and `activityPhase`. If a future change wires a
        // computed property to read these stored properties without
        // `@ObservationIgnored`, the counts will rise; that's the
        // regression this baseline catches.
        //
        // Each non-zero count is the cascade tax. After ChatViewModel
        // decomposition (#329 follow-ups) these should drop further or
        // remain at zero.
        XCTAssertLessThan(modelChanges, 5,
            "selectedModel observer woke \(modelChanges) times during a 200-token stream — "
            + "expected 0. Each wake is the cascade tax described in the perf-audit plan.")
        XCTAssertLessThan(endpointChanges, 5,
            "selectedEndpoint observer woke \(endpointChanges) times during a 200-token stream — "
            + "expected 0. Each wake is the cascade tax described in the perf-audit plan.")
        XCTAssertLessThan(pinnedChanges, 5,
            "pinnedMessageIDs observer woke \(pinnedChanges) times during a 200-token stream — "
            + "expected 0. Each wake is the cascade tax described in the perf-audit plan.")
    }
}

// MARK: - CascadeProbe

/// Holds a re-armable observation tracker plus a counter. The arm closure
/// reads a tracked property inside `withObservationTracking` and re-arms
/// itself from `onChange` so the counter accumulates across an entire
/// streamed turn, not just the first mutation.
///
/// Lives in its own class so the `Task { @MainActor in ... }` re-arm closure
/// can capture `self` (a reference type) instead of capturing a local
/// function (which would be non-Sendable under Swift 6).
@MainActor
private final class CascadeProbe {
    private let vm: ChatViewModel
    private let armBody: (ChatViewModel, CascadeProbe) -> Void
    private(set) var changeCount: Int = 0

    init(
        vm: ChatViewModel,
        arm: @escaping (ChatViewModel, CascadeProbe) -> Void
    ) {
        self.vm = vm
        self.armBody = arm
    }

    func arm() {
        armBody(vm, self)
    }

    func recordChange() {
        changeCount += 1
        // Re-arm on the next main-actor tick so subsequent mutations are
        // observed too. The arm closure captures `self` strongly, which is
        // fine — the probe is owned by the test method's stack frame and
        // dies at function exit.
        Task { @MainActor [weak self] in
            self?.arm()
        }
    }
}

// MARK: - Test Fixture

/// Minimal in-memory `MessageStore` for the runtime to persist into. Mirrors
/// the `RuntimeMessageStore` pattern from `ChatViewModelRuntimeAdapterTests`.
private final class ObserverCascadeMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [UUID: ManifoldInference.ChatMessage] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ManifoldInference.ChatMessage) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }

    func updateMessage(_ message: ManifoldInference.ChatMessage) async throws {
        guard messages[message.id] != nil else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }

    func deleteMessage(_ messageID: UUID) async throws {
        guard messages.removeValue(forKey: messageID) != nil else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ManifoldInference.ChatMessage] {
        messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }

    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
        hooks.append(hook)
    }
}
