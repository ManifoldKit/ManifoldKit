import XCTest
@testable import ManifoldRuntime

/// Unit tests for ``ConversationTurnTaskRegistry`` cleanup guarantees.
///
/// The registry launches detached turn tasks that unregister themselves on
/// completion. Earlier the cleanup ran through a `[weak self]` capture, so a
/// task whose owning runtime deallocated mid-flight would skip `unregister`
/// and leave a permanent entry in `tasks`. These tests pin the completion-path
/// cleanup and prove the self-clearing capture does not leak the registry.
///
/// Classification: Unit (no SwiftData, no network — pure in-memory registry).
final class ConversationTurnTaskRegistryTests: XCTestCase {

    /// A completed task must remove its own handle from the registry so the
    /// per-runtime bookkeeping does not grow without bound.
    func test_launch_clearsEntryOnCompletion() async {
        let registry = ConversationTurnTaskRegistry()
        let handle = ConversationStreamHandle()
        let started = expectation(description: "operation started")
        let gate = TestGate()

        let task = await registry.launch(handle: handle) {
            started.fulfill()
            await gate.wait()
        }

        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(registry.count, 1, "entry should be present while running")

        await gate.open()
        await task.value

        XCTAssertEqual(registry.count, 0, "completed task must unregister its handle")
    }

    /// The strong `self` capture that guarantees cleanup must be transient: it
    /// is held only for the task's lifetime. Once the task completes and clears
    /// its entry, the registry must be free to deallocate — i.e. no permanent
    /// retain cycle. We launch a task, drop the only strong reference to the
    /// registry while the task runs, then let the task finish and confirm the
    /// registry deallocates.
    func test_registryDeallocates_afterTaskCompletes_underEarlyOwnerDrop() async {
        weak var weakRegistry: ConversationTurnTaskRegistry?
        let started = expectation(description: "operation started")
        let gate = TestGate()

        // Capture the task so it outlives the strong registry reference,
        // mirroring an owner that deallocates while generation is in flight.
        var task: Task<Void, Never>?

        do {
            let registry = ConversationTurnTaskRegistry()
            weakRegistry = registry
            let handle = ConversationStreamHandle()
            task = await registry.launch(handle: handle) {
                started.fulfill()
                await gate.wait()
            }
            await fulfillment(of: [started], timeout: 1.0)
            // `registry` goes out of scope here — only the task's transient
            // strong capture keeps it alive.
        }

        XCTAssertNotNil(weakRegistry, "registry stays alive while its task runs")

        await gate.open()
        await task?.value
        task = nil

        // Give the detached task's tail (the `defer { unregister }`) a turn.
        for _ in 0..<50 where weakRegistry != nil {
            await Task.yield()
        }

        XCTAssertNil(
            weakRegistry,
            "registry must deallocate once the completed task releases its transient strong capture"
        )
    }

    /// A one-shot gate the test can hold open from the operation body without
    /// capturing the non-`Sendable` `XCTestCase` itself. Mirrors the production
    /// `ConversationTurnTaskStartGate` shape.
    private actor TestGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }
}
