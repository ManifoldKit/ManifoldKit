import XCTest
import Foundation
import Darwin
@testable import BaseChatInference
import BaseChatRuntime
import BaseChatTestSupport

/// Soak runner: drives 200 sequential sends through `ConversationRuntime` +
/// `MockInferenceBackend` and measures resident-set-size (RSS) growth.
///
/// Uses `task_info(MACH_TASK_BASIC_INFO)` for memory sampling, which is
/// available on all Apple platforms without entitlements. The 50 MB ceiling
/// is intentionally loose — the goal is catching unbounded accumulation
/// (e.g. a retained store that grows O(N)), not preventing a fixed-size
/// warm-up allocation.
///
/// Mock-based, no hardware required. Runs with `RUN_OPERATIONAL_TESTS=1`.
@MainActor
final class SoakRunnerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run soak tests"
        )
    }

    // MARK: - RSS helper

    private static func currentRSSBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    // MARK: - Soak test

    /// 200-send loop through `ConversationRuntime` + `MockInferenceBackend`.
    ///
    /// Each send uses the same `sessionID`, driving the full path: user-message
    /// insert → detached generation task → token stream → assistant-message
    /// insert → streamFinished event. The in-memory store grows with each
    /// message but the growth must be bounded (no retained closures, no
    /// leaked generation tasks, no accumulating event backpressure).
    func test_soakRunner_200Sends_rssGrowthUnder50MB() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        // Use a short scripted reply so each turn is fast.
        backend.tokensToYield = ["ok"]

        let store = SoakMessageStore()
        let inferenceService = InferenceService(backend: backend, name: "Soak")
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inferenceService
        )
        let sessionID = UUID()

        // Warm up: one send before the baseline to exclude lazy-init allocations
        // (dispatch queues, first-insert overhead, etc.) from the measurement.
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "warmup"))
        try await drainUntilStreamFinished(runtime: runtime)

        let baselineRSS = Self.currentRSSBytes()

        for i in 0..<200 {
            // Vary the token text slightly to defeat any intern/cache path.
            backend.tokensToYield = ["tok\(i % 10)"]
            _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "msg \(i)"))
            try await drainUntilStreamFinished(runtime: runtime)
        }

        let finalRSS = Self.currentRSSBytes()
        let growthMB = Double(finalRSS - baselineRSS) / 1_048_576.0

        XCTAssertLessThan(
            growthMB, 50.0,
            "RSS grew \(String(format: "%.1f", growthMB)) MB over 200 sends; expected < 50 MB. "
            + "Likely cause: retained message store (\(store.messageCount) messages accumulated), "
            + "unreleased generation tasks, or event stream backpressure."
        )
    }

    // MARK: - Drain helper

    /// Iterates `runtime.events` until a `streamFinished` or `errorRaised` event
    /// arrives, or until a 5-second wall-clock deadline elapses.
    ///
    /// Each call must be preceded by a matching `send` — the runtime serialises
    /// turns so only one generation is in flight at a time. The deadline guards
    /// against a buggy backend that never emits a terminal event.
    private func drainUntilStreamFinished(
        runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws {
        let drainTask = Task { @MainActor in
            for await event in runtime.events {
                switch event {
                case .streamFinished: return
                case .errorRaised: return
                default: continue
                }
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await drainTask.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                drainTask.cancel()
                // Deadline elapsed without a terminal event — not a test failure
                // (the generation may have already finished); just continue.
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - In-memory MessageStore

    /// Minimal `MessageStore` that accumulates messages in a dictionary.
    ///
    /// The `messageCount` property is exposed so the failure message can report
    /// how many messages the store holds — useful when diagnosing whether an
    /// RSS regression is from the store itself or from leaked runtime state.
    @MainActor
    private final class SoakMessageStore: MessageStore {
        private var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        var messageCount: Int { messages.count }

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
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
}
