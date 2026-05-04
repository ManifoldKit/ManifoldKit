#if Fuzz
import XCTest
@testable import BaseChatFuzz

final class ParallelFuzzWorkerPlanTests: XCTestCase {

    func test_fuzzConfigDefaultWorkers_isOne() {
        XCTAssertEqual(FuzzConfig().workers, 1)
    }

    func test_workersRejectsZero() {
        XCTAssertThrowsError(
            try ParallelFuzzWorkerPlanner.makePlan(
                backend: .mock,
                requestedWorkers: 0,
                seed: 1,
                minutes: nil,
                iterations: 10
            )
        ) { error in
            XCTAssertEqual(error as? ParallelFuzzWorkerPlanError, .invalidWorkerCount(0))
        }
    }

    func test_iterationsShard_evenSplitWithRemainder() throws {
        let plan = try ParallelFuzzWorkerPlanner.makePlan(
            backend: .mock,
            requestedWorkers: 3,
            seed: 42,
            minutes: nil,
            iterations: 10
        )

        XCTAssertEqual(plan.map(\.iterations), [4, 3, 3])
        XCTAssertEqual(plan.compactMap(\.iterations).reduce(0, +), 10)
    }

    func test_seedDerivation_isDeterministicAndUnique() throws {
        let first = try ParallelFuzzWorkerPlanner.makePlan(
            backend: .mock,
            requestedWorkers: 4,
            seed: 42,
            minutes: 5,
            iterations: nil
        )
        let second = try ParallelFuzzWorkerPlanner.makePlan(
            backend: .mock,
            requestedWorkers: 4,
            seed: 42,
            minutes: 5,
            iterations: nil
        )

        XCTAssertEqual(first.map(\.seed), second.map(\.seed))
        XCTAssertEqual(Set(first.map(\.seed)).count, 4)
    }

    func test_backendWorkerLimitRejectsUnsafeBackends() {
        XCTAssertThrowsError(
            try ParallelFuzzWorkerPlanner.makePlan(
                backend: .llama,
                requestedWorkers: 2,
                seed: 1,
                minutes: 5,
                iterations: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ParallelFuzzWorkerPlanError,
                .backendWorkerLimit(backend: .llama, requested: 2, limit: 1)
            )
        }
    }

    func test_iterationBudgetCapsEffectiveWorkers() throws {
        let plan = try ParallelFuzzWorkerPlanner.makePlan(
            backend: .mock,
            requestedWorkers: 4,
            seed: 1,
            minutes: nil,
            iterations: 2
        )

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.map(\.iterations), [1, 1])
    }
}
#endif
