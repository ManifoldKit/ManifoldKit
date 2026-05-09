import Foundation

public struct ParallelFuzzWorkerSlice: Sendable, Equatable {
    public var index: Int
    public var seed: UInt64
    public var minutes: Int?
    public var iterations: Int?

    public init(index: Int, seed: UInt64, minutes: Int?, iterations: Int?) {
        self.index = index
        self.seed = seed
        self.minutes = minutes
        self.iterations = iterations
    }
}

public enum ParallelFuzzWorkerPlanError: Error, Equatable, Sendable {
    case invalidWorkerCount(Int)
    case backendWorkerLimit(backend: BackendChoice, requested: Int, limit: Int)
}

public enum ParallelFuzzWorkerPlanner {
    public static func workerLimit(for backend: BackendChoice) -> Int {
        switch backend {
        case .mock, .chaos, .ollama:
            return 4
        case .llama, .foundation, .mlx, .all:
            return 1
        }
    }

    public static func makePlan(
        backend: BackendChoice,
        requestedWorkers: Int,
        seed: UInt64,
        minutes: Int?,
        iterations: Int?
    ) throws -> [ParallelFuzzWorkerSlice] {
        guard requestedWorkers > 0 else {
            throw ParallelFuzzWorkerPlanError.invalidWorkerCount(requestedWorkers)
        }
        let limit = workerLimit(for: backend)
        guard requestedWorkers <= limit else {
            throw ParallelFuzzWorkerPlanError.backendWorkerLimit(
                backend: backend,
                requested: requestedWorkers,
                limit: limit
            )
        }

        let effectiveWorkers: Int
        if let iterations {
            effectiveWorkers = max(1, min(requestedWorkers, max(iterations, 1)))
        } else {
            effectiveWorkers = requestedWorkers
        }

        let iterationSlices = iterations.map { splitBudget($0, workers: effectiveWorkers) }
        return (0..<effectiveWorkers).map { index in
            ParallelFuzzWorkerSlice(
                index: index,
                seed: deriveSeed(base: seed, workerIndex: index),
                minutes: minutes,
                iterations: iterationSlices?[index]
            )
        }
    }

    public static func deriveSeed(base: UInt64, workerIndex: Int) -> UInt64 {
        var value = base ^ (0x9E3779B97F4A7C15 &* UInt64(workerIndex + 1))
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    private static func splitBudget(_ total: Int, workers: Int) -> [Int] {
        let base = total / workers
        let remainder = total % workers
        return (0..<workers).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }
}
