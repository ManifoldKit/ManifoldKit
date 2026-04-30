import XCTest
@testable import BaseChatRuntime
import BaseChatTestSupport

/// Covers both the scheduler protocol contract via ``MockBackgroundTaskScheduler``
/// and the watchdog logic in ``DefaultBackgroundTaskScheduler``.
///
/// Memory-budget tests inject a synthetic ``DefaultBackgroundTaskScheduler.MemorySampler``
/// rather than allocating real memory — that keeps the tests deterministic
/// and CI-safe. The watchdog logic exercised here is the same code path that
/// would fire under real `phys_footprint` pressure on device.
final class BackgroundTaskSchedulerTests: XCTestCase {

    // MARK: - Mock contract

    func test_mock_schedule_recordsCallAndRunsWork() async {
        let scheduler = MockBackgroundTaskScheduler()
        let didRun = expectation(description: "work ran")

        await scheduler.schedule(identifier: "test.run", budget: .default) {
            didRun.fulfill()
        }

        await fulfillment(of: [didRun], timeout: 1.0)
        XCTAssertEqual(scheduler.calls.map(\.identifier), ["test.run"])
        XCTAssertEqual(scheduler.calls.first?.budget, .default)
    }

    func test_mock_cancel_cancelsInFlightWork() async {
        let scheduler = MockBackgroundTaskScheduler()
        let started = expectation(description: "work started")
        let observedCancellation = expectation(description: "work observed cancel")

        await scheduler.schedule(identifier: "test.cancel", budget: .default) {
            started.fulfill()
            // Sleep until cancelled. `Task.sleep` throws on cancellation,
            // which is exactly what we want to observe.
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                observedCancellation.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        await fulfillment(of: [started], timeout: 1.0)
        scheduler.cancel(identifier: "test.cancel")
        await fulfillment(of: [observedCancellation], timeout: 1.0)
        XCTAssertEqual(scheduler.cancellations, ["test.cancel"])
    }

    func test_mock_simulateBudgetExceeded_cancelsWork() async {
        let scheduler = MockBackgroundTaskScheduler()
        let started = expectation(description: "work started")
        let observedCancellation = expectation(description: "work observed cancel")

        await scheduler.schedule(identifier: "test.budget", budget: .default) {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                observedCancellation.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        await fulfillment(of: [started], timeout: 1.0)
        scheduler.simulateMemoryBudgetExceeded(identifier: "test.budget")
        await fulfillment(of: [observedCancellation], timeout: 1.0)
    }

    func test_mock_scheduleSameIdentifierTwice_replacesPriorRun() async {
        let scheduler = MockBackgroundTaskScheduler()
        let firstStarted = expectation(description: "first started")
        let firstObservedCancel = expectation(description: "first cancelled")
        let secondRan = expectation(description: "second ran")

        await scheduler.schedule(identifier: "test.replace", budget: .default) {
            firstStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                firstObservedCancel.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        await fulfillment(of: [firstStarted], timeout: 1.0)

        await scheduler.schedule(identifier: "test.replace", budget: .default) {
            secondRan.fulfill()
        }

        await fulfillment(of: [firstObservedCancel, secondRan], timeout: 1.0)
        XCTAssertEqual(scheduler.calls.count, 2)
    }

    // MARK: - DefaultBackgroundTaskScheduler — watchdog

    func test_default_runsWorkToCompletion_whenUnderBudget() async {
        // Sampler returns a value well under the budget; watchdog never trips.
        let scheduler = DefaultBackgroundTaskScheduler(memorySampler: { 1_000 })
        let didRun = expectation(description: "work ran")

        await scheduler.schedule(
            identifier: "default.under",
            budget: MemoryBudget(maxBytes: 10_000_000, sampleInterval: .milliseconds(20))
        ) {
            didRun.fulfill()
        }

        await fulfillment(of: [didRun], timeout: 1.0)
    }

    func test_default_cancelsWork_whenMemoryBudgetExceeded() async {
        // Sampler reports a value above the ceiling, so the watchdog will
        // cancel on its first tick. The closure is parked in `Task.sleep`
        // so cancellation is the only way out.
        let scheduler = DefaultBackgroundTaskScheduler(memorySampler: { 100_000_000 })
        let started = expectation(description: "work started")
        let cancelled = expectation(description: "work observed cancel")

        await scheduler.schedule(
            identifier: "default.budget",
            budget: MemoryBudget(maxBytes: 10_000_000, sampleInterval: .milliseconds(20))
        ) {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
                XCTFail("expected cancellation before sleep returned")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        await fulfillment(of: [started, cancelled], timeout: 2.0)
    }

    func test_default_explicitCancel_cancelsWork() async {
        let scheduler = DefaultBackgroundTaskScheduler(memorySampler: { 1_000 })
        let started = expectation(description: "work started")
        let cancelled = expectation(description: "work observed cancel")

        await scheduler.schedule(
            identifier: "default.cancel",
            budget: MemoryBudget(maxBytes: 10_000_000, sampleInterval: .milliseconds(20))
        ) {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
                XCTFail("expected cancellation")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        await fulfillment(of: [started], timeout: 1.0)
        scheduler.cancel(identifier: "default.cancel")
        await fulfillment(of: [cancelled], timeout: 1.0)
    }

    // MARK: - Recommended identifiers

    func test_recommendedIdentifiers_areStableStrings() {
        // Stable across releases — apps put these in Info.plist.
        XCTAssertEqual(BaseChatBackgroundTaskIdentifiers.postGeneration,
                       "com.basechatkit.background.post-generation")
        XCTAssertEqual(BaseChatBackgroundTaskIdentifiers.indexing,
                       "com.basechatkit.background.indexing")
        XCTAssertEqual(BaseChatBackgroundTaskIdentifiers.archive,
                       "com.basechatkit.background.archive")
    }
}
