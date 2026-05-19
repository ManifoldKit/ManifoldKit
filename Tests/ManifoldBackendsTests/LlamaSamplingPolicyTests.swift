#if Llama
import XCTest
@testable import ManifoldLlama

/// Unit tests for `LlamaSamplingPolicy` — verifies the consolidated
/// hardware-selection logic shared between `LlamaModelLoader` and
/// `LlamaEmbeddingBackend`. The policy takes its inputs as parameters so
/// these tests don't have to mutate `ProcessInfo` env or hardware globals.
final class LlamaSamplingPolicyTests: XCTestCase {

    // MARK: - gpuLayerCount

    #if targetEnvironment(simulator)
    func test_gpuLayerCount_isZeroInSimulator_regardlessOfEnv() {
        // In the simulator the policy hardcodes 0 — Metal is unreliable there
        // and tests skip GPU paths anyway. The env-injection branch is dead
        // code under simulator builds.
        XCTAssertEqual(LlamaSamplingPolicy.gpuLayerCount(environment: [:]), 0)
        XCTAssertEqual(
            LlamaSamplingPolicy.gpuLayerCount(environment: ["LLAMA_FORCE_CPU_ONLY": "1"]),
            0
        )
    }
    #else
    func test_gpuLayerCount_forceCPUEnvReturnsZero_onDevice() {
        XCTAssertEqual(
            LlamaSamplingPolicy.gpuLayerCount(environment: ["LLAMA_FORCE_CPU_ONLY": "1"]),
            0
        )
    }

    func test_gpuLayerCount_defaultsTo99_onDevice() {
        XCTAssertEqual(LlamaSamplingPolicy.gpuLayerCount(environment: [:]), 99)
        // A non-"1" value must not trigger the escape hatch.
        XCTAssertEqual(
            LlamaSamplingPolicy.gpuLayerCount(environment: ["LLAMA_FORCE_CPU_ONLY": "0"]),
            99
        )
        XCTAssertEqual(
            LlamaSamplingPolicy.gpuLayerCount(environment: ["LLAMA_FORCE_CPU_ONLY": "true"]),
            99
        )
    }
    #endif

    // MARK: - threadCount

    func test_threadCount_clampsToOneOnLowCoreCount() {
        // processorCount - 2 = -1, which the policy must floor at 1.
        XCTAssertEqual(LlamaSamplingPolicy.threadCount(processorCount: 1), 1)
    }

    func test_threadCount_reservesTwoCoresWithinBand() {
        // 4 - 2 = 2 (within the [1, 8] band).
        XCTAssertEqual(LlamaSamplingPolicy.threadCount(processorCount: 4), 2)
    }

    func test_threadCount_clampsToEightAtUpperBound() {
        // 10 - 2 = 8 — exact upper-band match.
        XCTAssertEqual(LlamaSamplingPolicy.threadCount(processorCount: 10), 8)
    }

    func test_threadCount_saturatesAtEightForLargeMachines() {
        // 100 - 2 = 98, clamped down to 8.
        XCTAssertEqual(LlamaSamplingPolicy.threadCount(processorCount: 100), 8)
    }
}
#endif
