import Testing
import Foundation
@testable import ManifoldInference

@Suite("ModelCapabilityTier")
struct ModelCapabilityTierTests {

    // MARK: - Comparable ordering

    @Test("Tiers are ordered minimal < fast < balanced < capable < frontier")
    func tierOrdering() {
        #expect(ModelCapabilityTier.minimal < .fast)
        #expect(ModelCapabilityTier.fast < .balanced)
        #expect(ModelCapabilityTier.balanced < .capable)
        #expect(ModelCapabilityTier.capable < .frontier)

        // Confirm total ordering is consistent with rawValue.
        let sorted: [ModelCapabilityTier] = [.frontier, .capable, .fast, .minimal, .balanced]
            .sorted()
        #expect(sorted == [.minimal, .fast, .balanced, .capable, .frontier])
    }

    // MARK: - Codable round-trip

    @Test("Codable round-trip preserves all tier values")
    func codableRoundTrip() throws {
        let tiers: [ModelCapabilityTier] = [.minimal, .fast, .balanced, .capable, .frontier]
        for tier in tiers {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(ModelCapabilityTier.self, from: data)
            #expect(decoded == tier)
        }
    }

    // MARK: - Static estimation by file size

    @Test("1 GB model estimates .minimal")
    func estimate_1gb_isMinimal() {
        let model = makeModel(fileSizeGB: 1, modelType: .gguf)
        #expect(ModelCapabilityTier.estimate(from: model) == .minimal)
    }

    @Test("3 GB model estimates .fast")
    func estimate_3gb_isFast() {
        let model = makeModel(fileSizeGB: 3, modelType: .gguf)
        #expect(ModelCapabilityTier.estimate(from: model) == .fast)
    }

    @Test("7 GB model estimates .balanced")
    func estimate_7gb_isBalanced() {
        let model = makeModel(fileSizeGB: 7, modelType: .gguf)
        #expect(ModelCapabilityTier.estimate(from: model) == .balanced)
    }

    @Test("15 GB model estimates .capable")
    func estimate_15gb_isCapable() {
        let model = makeModel(fileSizeGB: 15, modelType: .gguf)
        #expect(ModelCapabilityTier.estimate(from: model) == .capable)
    }

    @Test("30 GB model estimates .frontier")
    func estimate_30gb_isFrontier() {
        let model = makeModel(fileSizeGB: 30, modelType: .gguf)
        #expect(ModelCapabilityTier.estimate(from: model) == .frontier)
    }

    @Test("MLX model follows same file-size rules")
    func estimate_mlxModel_followsSizeRules() {
        let model = makeModel(fileSizeGB: 7, modelType: .mlx)
        #expect(ModelCapabilityTier.estimate(from: model) == .balanced)
    }

    @Test("Foundation model always estimates .fast")
    func estimate_foundationModel_isFast() {
        let model = makeModel(fileSizeGB: 0, modelType: .foundation)
        #expect(ModelCapabilityTier.estimate(from: model) == .fast)
    }

    // MARK: - Label

    @Test("label is non-empty for every case")
    func labelIsNonEmpty() {
        let tiers: [ModelCapabilityTier] = [.minimal, .fast, .balanced, .capable, .frontier]
        for tier in tiers {
            #expect(!tier.label.isEmpty)
        }
    }

    @Test("label values are distinct")
    func labelsAreDistinct() {
        let labels = ModelCapabilityTier.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // MARK: - Helpers

    private func makeModel(fileSizeGB: Double, modelType: ModelType) -> ModelInfo {
        let bytes = UInt64(fileSizeGB * 1_073_741_824)
        return ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: bytes,
            modelType: modelType
        )
    }
}

// ModelCapabilityTier needs CaseIterable for the label distinctness test.
extension ModelCapabilityTier: CaseIterable {
    public static var allCases: [ModelCapabilityTier] {
        [.minimal, .fast, .balanced, .capable, .frontier]
    }
}
