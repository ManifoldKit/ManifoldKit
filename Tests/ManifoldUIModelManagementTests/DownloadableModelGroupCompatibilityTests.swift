@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
@testable import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData

/// Tests for device-compatibility-based group sorting (issue #307) and
/// recommended-variant selection (issue #308).
@MainActor
final class DownloadableModelGroupCompatibilityTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    // MARK: - Helpers

    private func makeModel(
        repoID: String,
        fileName: String,
        sizeBytes: UInt64,
        downloads: Int = 0
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: fileName,
            modelType: .gguf,
            sizeBytes: sizeBytes,
            downloads: downloads
        )
    }

    // MARK: - Issue #307: Sort groups by device compatibility

    func test_group_sortKey_compatibleGroupRanksBeforeIncompatible() {
        // 8 GB device: 4 GB model fits, 70B (~40 GB) does not.
        let device = DeviceCapabilityService(physicalMemory: 8 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let smallModel = makeModel(repoID: "repo/small", fileName: "small-q4.gguf", sizeBytes: 4 * oneGB, downloads: 100)
        let largeModel = makeModel(repoID: "repo/large", fileName: "large-q4.gguf", sizeBytes: 38 * oneGB, downloads: 10_000)

        let groups = DownloadableModelGroup.group(
            [smallModel, largeModel],
            sortKey: { vm.compatibilityTier(for: $0) }
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.repoID, "repo/small",
            "Compatible group should rank first even when incompatible group has higher download count")
    }

    func test_group_sortKey_withinSameTierSortsByDownloads() {
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)

        // Both models fit on the 16 GB device — sort within tier by downloads.
        let modelA = makeModel(repoID: "repo/a", fileName: "a-q4.gguf", sizeBytes: 4 * oneGB, downloads: 500)
        let modelB = makeModel(repoID: "repo/b", fileName: "b-q4.gguf", sizeBytes: 4 * oneGB, downloads: 1_000)

        let vm = ModelManagementViewModel(deviceCapability: device)
        let groups = DownloadableModelGroup.group(
            [modelA, modelB],
            sortKey: { vm.compatibilityTier(for: $0) }
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.repoID, "repo/b",
            "Within the same compatibility tier, higher download count should rank first")
    }

    func test_group_sortKey_unknownSizeRanksLast() {
        let device = DeviceCapabilityService(physicalMemory: 8 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let knownModel = makeModel(repoID: "repo/known", fileName: "known.gguf", sizeBytes: 4 * oneGB, downloads: 1_000)
        let unknownModel = makeModel(repoID: "repo/unknown", fileName: "unknown.gguf", sizeBytes: 0, downloads: 5_000)

        let groups = DownloadableModelGroup.group(
            [knownModel, unknownModel],
            sortKey: { vm.compatibilityTier(for: $0) }
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.repoID, "repo/known",
            "Group with known size (compatible) should rank before group with unknown size")
    }

    func test_group_withoutSortKey_sortsByDownloadsOnly() {
        // Default behavior unchanged: sorts by download count descending.
        let modelA = makeModel(repoID: "repo/a", fileName: "a.gguf", sizeBytes: 0, downloads: 100)
        let modelB = makeModel(repoID: "repo/b", fileName: "b.gguf", sizeBytes: 0, downloads: 9_000)

        let groups = DownloadableModelGroup.group([modelA, modelB])

        XCTAssertEqual(groups.first?.repoID, "repo/b",
            "Without sort key, highest download count should rank first")
    }

    // MARK: - Issue #308: Recommended variant selection

    func test_recommendedVariant_allFit_returnsLargest() {
        // 16 GB device: all three variants fit. Expect the largest (6 GB).
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)

        let models = [
            makeModel(repoID: "repo/model", fileName: "model-q4.gguf", sizeBytes: 4 * oneGB),
            makeModel(repoID: "repo/model", fileName: "model-q6.gguf", sizeBytes: 6 * oneGB),
            makeModel(repoID: "repo/model", fileName: "model-q2.gguf", sizeBytes: 2 * oneGB),
        ]
        let groups = DownloadableModelGroup.group(models)
        guard let group = groups.first else {
            return XCTFail("Expected one group")
        }

        let rec = group.recommendedVariant(for: device)
        XCTAssertEqual(rec?.fileName, "model-q6.gguf",
            "When all variants fit, the largest should be recommended")
    }

    func test_recommendedVariant_partialFit_returnsLargestFitting() {
        // 8 GB device (allow threshold = 6.8 GB with ModelLoadPlan): 4 GB fits, 8 GB does not.
        let device = DeviceCapabilityService(physicalMemory: 8 * oneGB)

        let models = [
            makeModel(repoID: "repo/model", fileName: "model-q4.gguf", sizeBytes: 4 * oneGB),
            makeModel(repoID: "repo/model", fileName: "model-q6.gguf", sizeBytes: 8 * oneGB),
        ]
        let groups = DownloadableModelGroup.group(models)
        guard let group = groups.first else {
            return XCTFail("Expected one group")
        }

        let rec = group.recommendedVariant(for: device)
        XCTAssertEqual(rec?.fileName, "model-q4.gguf",
            "When only some variants fit, the largest fitting variant should be recommended")
    }

    func test_recommendedVariant_noneFit_returnsSmallest() {
        // 4 GB device: neither a 6 GB nor a 10 GB model fits. Expect the smallest.
        let device = DeviceCapabilityService(physicalMemory: 4 * oneGB)

        let models = [
            makeModel(repoID: "repo/model", fileName: "model-q4.gguf", sizeBytes: 6 * oneGB),
            makeModel(repoID: "repo/model", fileName: "model-q8.gguf", sizeBytes: 10 * oneGB),
        ]
        let groups = DownloadableModelGroup.group(models)
        guard let group = groups.first else {
            return XCTFail("Expected one group")
        }

        let rec = group.recommendedVariant(for: device)
        XCTAssertEqual(rec?.fileName, "model-q4.gguf",
            "When no variant fits, the smallest should be returned as fallback")
    }

    func test_recommendedVariant_singleVariant_returnsThatVariant() {
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)

        let models = [
            makeModel(repoID: "repo/model", fileName: "only.gguf", sizeBytes: 4 * oneGB),
        ]
        let groups = DownloadableModelGroup.group(models)
        guard let group = groups.first else {
            return XCTFail("Expected one group")
        }

        let rec = group.recommendedVariant(for: device)
        XCTAssertEqual(rec?.fileName, "only.gguf",
            "Single-variant group should always recommend that variant")
    }

    func test_recommendedVariant_allUnknownSize_returnsFirst() {
        // All variants have sizeBytes == 0 — no size info. Should fall back to first.
        let device = DeviceCapabilityService(physicalMemory: 8 * oneGB)

        let models = [
            makeModel(repoID: "repo/model", fileName: "model-a.gguf", sizeBytes: 0),
            makeModel(repoID: "repo/model", fileName: "model-b.gguf", sizeBytes: 0),
        ]
        let groups = DownloadableModelGroup.group(models)
        guard let group = groups.first else {
            return XCTFail("Expected one group")
        }

        let rec = group.recommendedVariant(for: device)
        // Variants are sorted ascending by sizeBytes (both 0), so first is stable.
        XCTAssertNotNil(rec, "Should return a variant even when all sizes are unknown")
    }

    func test_recommendedVariant_emptyGroup_returnsNil() {
        // Construct a group manually with no variants.
        let group = DownloadableModelGroup(
            id: "empty/repo",
            repoID: "empty/repo",
            displayName: "Empty",
            downloads: nil,
            variants: []
        )
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)
        XCTAssertNil(group.recommendedVariant(for: device),
            "Empty group should return nil for recommended variant")
    }

    // MARK: - compatibilityTier via ModelManagementViewModel

    func test_compatibilityTier_comfortableFit_returnsZero() {
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let models = [makeModel(repoID: "repo/a", fileName: "a.gguf", sizeBytes: 4 * oneGB)]
        let group = DownloadableModelGroup.group(models).first!

        XCTAssertEqual(vm.compatibilityTier(for: group), 0)
    }

    func test_compatibilityTier_borderlineFit_returnsOne() {
        // A 6 GB device (allow threshold = 5.1 GB with ModelLoadPlan) cannot fit a 6 GB
        // model outright (6 > 5.1), but the 80% threshold check passes (4.8 ≤ 5.1).
        let device = DeviceCapabilityService(physicalMemory: 6 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let models = [makeModel(repoID: "repo/a", fileName: "a.gguf", sizeBytes: 6 * oneGB)]
        let group = DownloadableModelGroup.group(models).first!

        XCTAssertEqual(vm.compatibilityTier(for: group), 1,
            "A model that fails the full check but passes at 80% of declared size should be tier 1 (borderline)")
    }

    func test_compatibilityTier_allTooLarge_returnsTwo() {
        let device = DeviceCapabilityService(physicalMemory: 4 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let models = [makeModel(repoID: "repo/a", fileName: "a.gguf", sizeBytes: 40 * oneGB)]
        let group = DownloadableModelGroup.group(models).first!

        XCTAssertEqual(vm.compatibilityTier(for: group), 2)
    }

    func test_compatibilityTier_unknownSize_returnsThree() {
        let device = DeviceCapabilityService(physicalMemory: 16 * oneGB)
        let vm = ModelManagementViewModel(deviceCapability: device)

        let models = [makeModel(repoID: "repo/a", fileName: "a.gguf", sizeBytes: 0)]
        let group = DownloadableModelGroup.group(models).first!

        XCTAssertEqual(vm.compatibilityTier(for: group), 3)
    }
}
