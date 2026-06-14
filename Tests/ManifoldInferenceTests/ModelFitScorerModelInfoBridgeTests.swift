import XCTest
@testable import ManifoldInference

/// Unit tests for the `ModelFitScorer.score(_ model: ModelInfo, ...)` bridge.
///
/// The bridge lets the scorer rank the models a user actually has on disk
/// (`ModelRegistry.availableModels` is `[ModelInfo]`). Inputs are injected
/// (device profile + memory environment) so results are deterministic.
final class ModelFitScorerModelInfoBridgeTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    // MARK: - Fixtures

    /// A GGUF on-disk fixture. `quant` is encoded into the filename so the
    /// production `ModelInfo.quantization` regex extracts it, exactly as the
    /// `DownloadableModel` fixtures do for the downloadable scoring path.
    private func ggufModel(
        sizeGB: Double,
        quant: String,
        name: String = "Model",
        contextLength: Int? = nil
    ) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).\(quant).gguf",
            url: URL(fileURLWithPath: "/virtual/\(name).\(quant).gguf"),
            fileSize: UInt64(sizeGB * Double(oneGB)),
            modelType: .gguf,
            detectedContextLength: contextLength
        )
    }

    private func device(ramGB: UInt64, bandwidthGBs: Double) -> DeviceProfile {
        let bytes = ramGB * oneGB
        return DeviceProfile(
            physicalMemoryBytes: bytes,
            usableMemoryBytes: bytes,
            memoryBandwidthGBs: bandwidthGBs
        )
    }

    private func environment(for device: DeviceProfile) -> ModelLoadPlan.Environment {
        ModelLoadPlan.Environment(
            availableMemoryBytes: { device.usableMemoryBytes },
            physicalMemoryBytes: device.physicalMemoryBytes
        )
    }

    // MARK: - Quantization parsing

    func test_modelInfo_quantization_parsedFromFileName() {
        XCTAssertEqual(ggufModel(sizeGB: 4, quant: "Q4_K_M").quantization, "Q4_K_M")
        XCTAssertEqual(ggufModel(sizeGB: 4, quant: "Q8_0").quantization, "Q8_0")
        XCTAssertEqual(ggufModel(sizeGB: 4, quant: "IQ2_XS").quantization, "IQ2_XS")
    }

    func test_modelInfo_quantization_nilForNonGGUF() {
        let mlx = ModelInfo(
            name: "snap",
            fileName: "mlx-community/snap",
            url: URL(fileURLWithPath: "/virtual/snap"),
            fileSize: oneGB,
            modelType: .mlx
        )
        XCTAssertNil(mlx.quantization)
    }

    // MARK: - Scoring

    func test_score_returnsNilForZeroByteNonFoundationModel() {
        let scorer = ModelFitScorer()
        let empty = ModelInfo(
            name: "empty",
            fileName: "empty.Q4_K_M.gguf",
            url: URL(fileURLWithPath: "/virtual/empty.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        XCTAssertNil(scorer.score(empty, useCase: .general))
    }

    func test_score_foundationModel_isScoredDespiteZeroFileSize() {
        let scorer = ModelFitScorer()
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let score = scorer.score(
            ModelInfo.builtInFoundation,
            useCase: .general,
            device: dev,
            environment: environment(for: dev)
        )
        XCTAssertNotNil(score)
        // OS-resident: the load plan always allows, so it must rank as runnable.
        XCTAssertTrue(score?.willRun ?? false)
    }

    func test_smallQ4_outranks_largeQ2_onTightMemory() {
        // 8 GB device: the ~5.5 GB Q2 is a tight/over fit while the ~4 GB Q4 fits
        // comfortably AND has the wider quant. Composite should favour the Q4.
        let dev = device(ramGB: 8, bandwidthGBs: 100)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let smallQ4 = ggufModel(sizeGB: 4.0, quant: "Q4_K_M", name: "Seven")
        let bigQ2 = ggufModel(sizeGB: 5.5, quant: "Q2_K", name: "Thirteen")

        let s7 = scorer.score(smallQ4, useCase: .general, device: dev, environment: env)
        let s13 = scorer.score(bigQ2, useCase: .general, device: dev, environment: env)

        XCTAssertNotNil(s7)
        XCTAssertNotNil(s13)
        XCTAssertGreaterThan(s7!.composite, s13!.composite)
    }

    func test_oversizeModel_denied_collapsesBelowRunnable() {
        // A 40 GB model on a 8 GB device cannot load: willRun == false and the
        // composite must collapse below any runnable candidate.
        let dev = device(ramGB: 8, bandwidthGBs: 100)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let huge = ggufModel(sizeGB: 40.0, quant: "Q4_K_M", name: "Seventy")
        let small = ggufModel(sizeGB: 3.0, quant: "Q4_K_M", name: "Three")

        let sHuge = scorer.score(huge, useCase: .reasoning, device: dev, environment: env)
        let sSmall = scorer.score(small, useCase: .reasoning, device: dev, environment: env)

        XCTAssertNotNil(sHuge)
        XCTAssertNotNil(sSmall)
        XCTAssertFalse(sHuge!.willRun)
        XCTAssertGreaterThan(sSmall!.composite, sHuge!.composite)
    }

    func test_rank_ordersByCompositeBestFirst_andDropsUnscoreable() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let good = ggufModel(sizeGB: 7.0, quant: "Q5_K_M", name: "Good", contextLength: 8_192)
        let weak = ggufModel(sizeGB: 1.5, quant: "Q2_K", name: "Weak")
        let empty = ModelInfo(
            name: "empty",
            fileName: "empty.Q4_K_M.gguf",
            url: URL(fileURLWithPath: "/virtual/empty.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        let ranked = scorer.rank([weak, good, empty], useCase: .general, device: dev, environment: env)

        // Empty (size 0) is dropped; the rest are ordered best-first.
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.0.name, "Good")
        XCTAssertGreaterThanOrEqual(ranked[0].1.composite, ranked[1].1.composite)
    }

    func test_contextDimension_reactsToDetectedContextLength() {
        // Coding needs 32k context; a model that declares 32k should score at least
        // as high on context as an otherwise-identical model with no declared length.
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let withCtx = ggufModel(sizeGB: 7.0, quant: "Q4_K_M", name: "Ctx", contextLength: 32_768)
        let noCtx = ggufModel(sizeGB: 7.0, quant: "Q4_K_M", name: "NoCtx", contextLength: nil)

        let sCtx = scorer.score(withCtx, useCase: .coding, device: dev, environment: env)
        let sNo = scorer.score(noCtx, useCase: .coding, device: dev, environment: env)

        XCTAssertNotNil(sCtx)
        XCTAssertNotNil(sNo)
        XCTAssertGreaterThan(sCtx!.context, sNo!.context)
    }
}
