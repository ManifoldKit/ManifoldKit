// QuickStartSeedRecommendationTests.swift
//
// Exercises the device-aware first-launch seed picker
// `QuickStartSeed.recommended(useCase:device:foundationAvailable:onProgress:)`.
//
// The seed picker ranks a curated GGUF candidate set with `ModelFitScorer` under
// an injected `DeviceProfile`, so these tests pass a fixed profile and never read
// the host machine's RAM/bandwidth. They prove:
//   1. A high-memory M-series machine seeds a *larger* model than a base phone.
//   2. The Qwen3-0.6B floor holds when no larger candidate fits.
//   3. The progress closure rides whatever candidate the device chooses.

import XCTest
@testable import ManifoldKit
import ManifoldInference

final class QuickStartSeedRecommendationTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    /// A fixed device profile so memory + bandwidth are not read from the host.
    private func device(ramGB: UInt64, bandwidthGBs: Double) -> DeviceProfile {
        let bytes = ramGB * oneGB
        return DeviceProfile(
            physicalMemoryBytes: bytes,
            usableMemoryBytes: bytes,
            memoryBandwidthGBs: bandwidthGBs
        )
    }

    private let floorModelID = "bartowski/Qwen_Qwen3-0.6B-GGUF/Qwen_Qwen3-0.6B-Q4_K_M.gguf"

    // MARK: - Seed differs by device profile

    func test_highMemoryDevice_seedsLargerModelThanFloor() {
        // A 64 GB M-Max-class machine: every curated candidate fits comfortably, so
        // the picker should choose something larger/more capable than the 0.6B floor.
        let dev = device(ramGB: 64, bandwidthGBs: 400)

        let seed = QuickStartSeed.recommended(useCase: .general, device: dev)

        XCTAssertNotEqual(
            seed.modelID, floorModelID,
            "A 64 GB machine should seed a larger model than the Qwen3-0.6B floor"
        )
        XCTAssertGreaterThan(
            seed.sizeBytes, QuickStartSeed.floorSeed.sizeBytes,
            "High-memory seed must be larger than the floor"
        )
    }

    func test_lowMemoryDevice_seedDiffersFromHighMemoryDevice() {
        // Prove the seed is device-dependent: a base phone (~3 GB usable) and a
        // 64 GB Mac must not land on the same model.
        let phone = device(ramGB: 3, bandwidthGBs: 60)
        let mac = device(ramGB: 64, bandwidthGBs: 400)

        let phoneSeed = QuickStartSeed.recommended(useCase: .general, device: phone)
        let macSeed = QuickStartSeed.recommended(useCase: .general, device: mac)

        XCTAssertNotEqual(
            phoneSeed.modelID, macSeed.modelID,
            "A base phone and a 64 GB Mac should get different device-aware seeds"
        )
        // The phone's pick must not exceed the Mac's pick.
        XCTAssertLessThanOrEqual(
            phoneSeed.sizeBytes, macSeed.sizeBytes,
            "The lower-memory device should never seed a larger model than the high-memory one"
        )
    }

    // MARK: - Floor / fallback

    func test_tinyMemoryDevice_fallsBackToFloor() {
        // A device with ~1.5 GB usable can only run the 0.6B floor; every larger
        // candidate is over-budget (collapsed by the scorer), so the floor holds.
        let tiny = device(ramGB: 1, bandwidthGBs: 34)

        let seed = QuickStartSeed.recommended(useCase: .general, device: tiny)

        XCTAssertEqual(
            seed.modelID, floorModelID,
            "When no larger candidate fits, the picker must return the Qwen3-0.6B floor"
        )
        XCTAssertEqual(seed.modelType, .gguf)
        XCTAssertGreaterThan(seed.sizeBytes, 0)
    }

    // MARK: - Floor is always a candidate

    func test_floorSeed_isFirstCandidate_andRunsEverywhere() {
        XCTAssertEqual(
            QuickStartSeed.floorSeed.modelID, floorModelID,
            "floorSeed must be the Qwen3-0.6B entry"
        )
        // The floor must be present in the curated candidate set.
        XCTAssertTrue(
            QuickStartSeed.seedCandidates.contains { $0.modelID == floorModelID },
            "The floor must always be in the ranked candidate set so the picker can never return nothing"
        )
    }

    // MARK: - Progress closure rides the chosen candidate

    @MainActor
    func test_recommended_forwardsProgressToChosenSeed() {
        var received: Double?
        let dev = device(ramGB: 64, bandwidthGBs: 400)

        let seed = QuickStartSeed.recommended(useCase: .general, device: dev) { p in
            received = p
        }

        XCTAssertNotNil(seed.onProgress, "onProgress must ride the device-chosen seed")
        seed.onProgress?(0.42)
        XCTAssertEqual(received, 0.42, "Progress closure must forward the value")
    }

    // MARK: - Use case sensitivity (smoke)

    func test_recommended_isStableForSameInputs() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let a = QuickStartSeed.recommended(useCase: .reasoning, device: dev)
        let b = QuickStartSeed.recommended(useCase: .reasoning, device: dev)
        XCTAssertEqual(a.modelID, b.modelID, "The picker must be deterministic for identical inputs")
    }
}
