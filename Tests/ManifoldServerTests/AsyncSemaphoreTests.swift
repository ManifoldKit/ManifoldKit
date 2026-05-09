#if Server
@testable import ManifoldServer
import XCTest

final class AsyncSemaphoreTests: XCTestCase {
    func testInitClampsZeroToOne() {
        let semaphore = AsyncSemaphore(value: 0)
        // A limit-0 semaphore would deadlock on the first wait; clamping to 1 is the safe default.
        // Verify by waiting immediately — if clamped to 1 this returns without suspending.
        let expectation = XCTestExpectation(description: "wait returns without suspending")
        Task {
            try? await semaphore.wait()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testSingleWaiterUnblockedBySignal() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        // Drain the initial slot.
        try await semaphore.wait()

        let unblocked = XCTestExpectation(description: "waiter unblocked after signal")
        Task {
            try await semaphore.wait()
            unblocked.fulfill()
        }
        // Give the task a chance to suspend before we signal.
        try await Task.sleep(for: .milliseconds(50))
        await semaphore.signal()

        await fulfillment(of: [unblocked], timeout: 2)
        // SABOTAGE: remove the signal() call above to verify the waiter stays blocked
    }

    func testAvailableNeverExceedsLimit() async {
        let semaphore = AsyncSemaphore(value: 1)
        // Signal without a prior wait — available should stay capped at limit (1).
        for _ in 0..<5 {
            await semaphore.signal()
        }
        // Verify by waiting twice — the second should block (no second slot was created).
        let waited = XCTestExpectation(description: "first wait acquires slot")
        Task {
            try? await semaphore.wait()
            waited.fulfill()
        }
        await fulfillment(of: [waited], timeout: 1)

        // A second wait should not return immediately; it would block indefinitely if available > 1.
        // We verify the cap indirectly: if available were > 1, the expectation below would fulfil instantly.
        let shouldNotFulfil = XCTestExpectation(description: "second wait should stay queued")
        shouldNotFulfil.isInverted = true
        let second = Task {
            try? await semaphore.wait()
            shouldNotFulfil.fulfill()
        }
        await fulfillment(of: [shouldNotFulfil], timeout: 0.15)
        second.cancel()
    }

    func testConcurrentWaitersAreBoundedByLimit() async throws {
        let limit = 1
        let semaphore = AsyncSemaphore(value: limit)
        let recorder = ConcurrencyCounter()

        // Launch three concurrent tasks, each entering and holding the semaphore briefly.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try? await semaphore.wait()
                    await recorder.enter()
                    try? await Task.sleep(for: .milliseconds(50))
                    await recorder.leave()
                    await semaphore.signal()
                }
            }
        }

        let maxObserved = await recorder.maxObserved
        XCTAssertLessThanOrEqual(maxObserved, limit, "At most \(limit) tasks should hold the semaphore simultaneously")
        // SABOTAGE: change AsyncSemaphore(value: limit) to AsyncSemaphore(value: 3) to verify the bound is enforced
    }
}

private actor ConcurrencyCounter {
    private var current = 0
    private var max = 0
    var maxObserved: Int { max }

    func enter() {
        current += 1
        if current > max { max = current }
    }

    func leave() {
        current -= 1
    }
}

#endif
