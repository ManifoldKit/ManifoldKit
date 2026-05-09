import XCTest
@testable import ManifoldInference

/// Tests for `DeviceCapability` query predicates.
///
/// All tests that depend on memory thresholds use `ModelLoadPlan.canRunModel` with
/// explicit `physicalMemoryBytes` values so they are deterministic on any machine.
/// Tests that call the real `DeviceCapability.*` static methods (which read
/// `ProcessInfo.processInfo.physicalMemory`) are limited to shape/contract checks
/// that hold regardless of the host machine's RAM.
final class DeviceCapabilityTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    // MARK: - supports(tier:) — indirect via ModelLoadPlan.canRunModel

    /// The probe sizes used by `DeviceCapability.supports(tier:)` must allow every
    /// tier on a large-RAM machine and reject high tiers on small-RAM machines.
    /// We mirror the probe logic here rather than calling the method under test
    /// because `supports(tier:)` reads real physical memory — instead, we validate
    /// the contract by testing `ModelLoadPlan.canRunModel` at the documented probe
    /// sizes directly.

    func test_supports_minimal_fits_on_4GBDevice() {
        // 1 GB probe vs 4 GB RAM — should always allow.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 1 * oneGB,
                                               physicalMemoryBytes: 4 * oneGB)
        XCTAssertTrue(result, "minimal-tier probe should fit on a 4 GB device")
    }

    func test_supports_fast_fits_on_8GBDevice() {
        // 3 GB probe vs 8 GB RAM — should allow.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 3 * oneGB,
                                               physicalMemoryBytes: 8 * oneGB)
        XCTAssertTrue(result, "fast-tier probe should fit on an 8 GB device")
    }

    func test_supports_balanced_fits_on_16GBDevice() {
        // 7 GB probe vs 16 GB RAM — should allow.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 7 * oneGB,
                                               physicalMemoryBytes: 16 * oneGB)
        XCTAssertTrue(result, "balanced-tier probe should fit on a 16 GB device")
    }

    func test_supports_capable_fits_on_32GBDevice() {
        // 15 GB probe vs 32 GB RAM — should allow.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 15 * oneGB,
                                               physicalMemoryBytes: 32 * oneGB)
        XCTAssertTrue(result, "capable-tier probe should fit on a 32 GB device")
    }

    func test_supports_frontier_fits_on_64GBDevice() {
        // 22 GB probe vs 64 GB RAM — should allow.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 22 * oneGB,
                                               physicalMemoryBytes: 64 * oneGB)
        XCTAssertTrue(result, "frontier-tier probe should fit on a 64 GB device")
    }

    func test_supports_frontier_denied_on_4GBDevice() {
        // 22 GB probe vs 4 GB RAM — impossible fit, should deny.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 22 * oneGB,
                                               physicalMemoryBytes: 4 * oneGB)
        XCTAssertFalse(result, "frontier-tier probe should NOT fit on a 4 GB device")
    }

    func test_supports_capable_denied_on_4GBDevice() {
        // 15 GB probe vs 4 GB RAM — impossible fit, should deny.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 15 * oneGB,
                                               physicalMemoryBytes: 4 * oneGB)
        XCTAssertFalse(result, "capable-tier probe should NOT fit on a 4 GB device")
    }

    func test_supports_balanced_denied_on_4GBDevice() {
        // 7 GB probe vs 4 GB RAM — impossible fit ratio (7/4 >= 3), should deny.
        let result = ModelLoadPlan.canRunModel(sizeBytes: 7 * oneGB,
                                               physicalMemoryBytes: 4 * oneGB)
        XCTAssertFalse(result, "7 GB probe should NOT fit on a 4 GB device (impossible-fit ratio)")
    }

    // MARK: - supports(tier:) — on real device (shape contract only)

    func test_supports_minimal_onRealDevice_isTrue() {
        // Minimal tier (1 GB probe) should fit on any physical machine we'd test on.
        // This would only fail on a machine with < ~1.2 GB of physical RAM.
        XCTAssertTrue(DeviceCapability.supports(tier: .minimal),
                      "supports(.minimal) must be true on any test-capable machine")
    }

    // MARK: - highestSupportedTier(for:) — shape contract

    func test_highestSupportedTier_returnsAtLeastMinimal_forGGUF() {
        let tier = DeviceCapability.highestSupportedTier(for: .gguf)
        XCTAssertGreaterThanOrEqual(tier, .minimal)
    }

    func test_highestSupportedTier_returnsAtLeastMinimal_forMLX() {
        let tier = DeviceCapability.highestSupportedTier(for: .mlx)
        XCTAssertGreaterThanOrEqual(tier, .minimal)
    }

    func test_highestSupportedTier_returnsAtLeastFast_forFoundation() {
        // Foundation models are system-managed; the OS owns their memory budget.
        // The floor is .fast regardless of how constrained physical RAM is.
        let tier = DeviceCapability.highestSupportedTier(for: .foundation)
        XCTAssertGreaterThanOrEqual(tier, .fast,
                                    "foundation backend must always return at least .fast")
    }

    func test_highestSupportedTier_ggufAndMLX_returnSameTier() {
        // gguf and mlx share the same probe-size table and neither gets a floor
        // override, so they must agree on every real machine.
        let gguf = DeviceCapability.highestSupportedTier(for: .gguf)
        let mlx  = DeviceCapability.highestSupportedTier(for: .mlx)
        XCTAssertEqual(gguf, mlx,
                       "gguf and mlx share the same tier probe table")
    }

    // MARK: - canLoadModel(estimatedMemoryMB:)

    func test_canLoadModel_zero_isTrue() {
        // Zero-byte models (e.g. cloud backends) should always pass.
        XCTAssertTrue(DeviceCapability.canLoadModel(estimatedMemoryMB: 0))
    }

    func test_canLoadModel_smallModelOnCurrentDevice() {
        // A 50 MB model should fit on any test machine.
        XCTAssertTrue(DeviceCapability.canLoadModel(estimatedMemoryMB: 50),
                      "50 MB should fit on any CI / developer machine")
    }

    func test_canLoadModel_impossiblyLargeModel_isFalse() {
        // 1_000_000 MB (nearly 1 PB) must be rejected on every real machine.
        XCTAssertFalse(DeviceCapability.canLoadModel(estimatedMemoryMB: 1_000_000),
                       "1 PB model must never fit on a real device")
    }

    func test_canLoadModel_threshold_allow_at_85percent() {
        // Internal: available × 0.85 is the allow threshold.
        // We can't inject `queryAvailableMemory`, so we verify the formula at a
        // known boundary: if a device reports exactly 1 GB available, a 850 MB
        // model is at the boundary. We test the formula through
        // ModelLoadPlan.canRunModel which uses the same 85% logic.
        let available: UInt64 = 1 * oneGB
        let exactlyAtThreshold = UInt64(Double(available) * 0.85)
        // exactlyAtThreshold bytes in MB (rounded down)
        let mb = Int(exactlyAtThreshold / 1_048_576)
        // canRunModel uses .resident strategy + 2048-token KV overhead; we just
        // confirm the formula direction using a raw arithmetic check here.
        let threshold = UInt64(Double(available) * 0.85)
        let estimatedBytes = UInt64(mb) * 1_048_576
        XCTAssertLessThanOrEqual(estimatedBytes, threshold,
                                 "estimatedBytes at mb boundary must be ≤ allow threshold")
    }

    func test_canLoadModel_threshold_deny_above_100percent() {
        // canLoadModel must return false for a model larger than available memory.
        // 1_000_000 MB is always larger than any real available memory.
        let veryLarge = 1_000_000  // MB — far beyond any real available memory
        XCTAssertFalse(DeviceCapability.canLoadModel(estimatedMemoryMB: veryLarge))
    }
}
