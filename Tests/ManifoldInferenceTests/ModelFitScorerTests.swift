import XCTest
@testable import ManifoldInference

/// Unit tests for `ModelFitScorer` and the composite model-fit ranking.
///
/// All inputs are injected (device profile + memory environment) so results are
/// deterministic regardless of the host machine's RAM or chip.
final class ModelFitScorerTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    // MARK: - Fixtures

    /// A GGUF download fixture. `quant` is encoded into the filename so the
    /// production `DownloadableModel.quantization` regex extracts it.
    private func ggufModel(sizeGB: Double, quant: String, name: String = "Model") -> DownloadableModel {
        DownloadableModel(
            repoID: "test/\(name)-GGUF",
            fileName: "\(name).\(quant).gguf",
            displayName: "\(name) \(quant)",
            modelType: .gguf,
            sizeBytes: UInt64(sizeGB * Double(oneGB))
        )
    }

    /// A fixed device profile so bandwidth/memory are not read from the host.
    private func device(ramGB: UInt64, bandwidthGBs: Double) -> DeviceProfile {
        let bytes = ramGB * oneGB
        return DeviceProfile(
            physicalMemoryBytes: bytes,
            usableMemoryBytes: bytes,
            memoryBandwidthGBs: bandwidthGBs
        )
    }

    /// Memory environment matching a device profile, so `ModelLoadPlan.estimate`
    /// evaluates against the test's RAM rather than the real machine.
    private func environment(for device: DeviceProfile) -> ModelLoadPlan.Environment {
        ModelLoadPlan.Environment(
            availableMemoryBytes: { device.usableMemoryBytes },
            physicalMemoryBytes: device.physicalMemoryBytes
        )
    }

    // MARK: - Quality / size ordering

    func test_7B_Q4_outranks_13B_Q2_onSmallMemoryDevice() {
        // 8 GB device: the 13B-Q2 (~5 GB) is a tight/over fit while the 7B-Q4 (~4 GB)
        // fits comfortably AND has wider quant. Composite should favour the 7B-Q4.
        let dev = device(ramGB: 8, bandwidthGBs: 100)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let smallQ4 = ggufModel(sizeGB: 4.0, quant: "Q4_K_M", name: "Seven")
        let bigQ2 = ggufModel(sizeGB: 5.5, quant: "Q2_K", name: "Thirteen")

        let s7 = scorer.score(smallQ4, useCase: .general, device: dev, environment: env)
        let s13 = scorer.score(bigQ2, useCase: .general, device: dev, environment: env)

        XCTAssertNotNil(s7)
        XCTAssertNotNil(s13)
        XCTAssertGreaterThan(
            s7!.composite, s13!.composite,
            "7B-Q4 should outrank 13B-Q2 on a small-memory device"
        )
    }

    // MARK: - willRun gate via ModelLoadPlan

    func test_willRun_false_whenModelExceedsMemory() {
        // 4 GB device, 30 GB model: ModelLoadPlan's impossible-fit guard denies.
        let dev = device(ramGB: 4, bandwidthGBs: 68)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let huge = ggufModel(sizeGB: 30.0, quant: "Q4_K_M", name: "Seventy")
        let score = scorer.score(huge, useCase: .general, device: dev, environment: env)

        XCTAssertNotNil(score)
        XCTAssertFalse(score!.willRun, "30 GB model on 4 GB device must not be runnable")
        XCTAssertEqual(score!.fit, 0.0, "deny verdict maps to fit == 0")
    }

    func test_willRun_true_whenModelFitsComfortably() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let small = ggufModel(sizeGB: 4.0, quant: "Q4_K_M")
        let score = scorer.score(small, useCase: .general, device: dev, environment: env)

        XCTAssertNotNil(score)
        XCTAssertTrue(score!.willRun, "4 GB model on 16 GB device should run")
    }

    // MARK: - Use-case weighting shifts the ranking

    func test_chatFavoursSpeed_reasoningFavoursQuality() {
        // Two models that both fit: a small/fast one and a large/capable one.
        // `chat` (speed-weighted) should prefer the small model; `reasoning`
        // (quality-weighted) should prefer the large model. Same device for both.
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let fastSmall = ggufModel(sizeGB: 2.0, quant: "Q4_K_M", name: "Small")
        let capableBig = ggufModel(sizeGB: 14.0, quant: "Q5_K_M", name: "Big")

        let chatSmall = scorer.score(fastSmall, useCase: .chat, device: dev, environment: env)!
        let chatBig = scorer.score(capableBig, useCase: .chat, device: dev, environment: env)!
        XCTAssertGreaterThan(
            chatSmall.composite, chatBig.composite,
            "chat (speed-weighted) should prefer the smaller/faster model"
        )

        let reasonSmall = scorer.score(fastSmall, useCase: .reasoning, device: dev, environment: env)!
        let reasonBig = scorer.score(capableBig, useCase: .reasoning, device: dev, environment: env)!
        XCTAssertGreaterThan(
            reasonBig.composite, reasonSmall.composite,
            "reasoning (quality-weighted) should prefer the larger/more-capable model"
        )
    }

    // MARK: - rank() ordering

    func test_rank_returnsBestFirst() {
        // 8 GB device. The 30 GB model trips ModelLoadPlan's impossible-fit guard
        // (30/8 ≥ 3× available) → .deny → willRun == false, so the willRun gate must
        // push it last despite its frontier-tier size.
        let dev = device(ramGB: 8, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let wontFit = ggufModel(sizeGB: 30.0, quant: "Q4_K_M", name: "Wont-Fit")
        let goodFit = ggufModel(sizeGB: 4.0, quant: "Q4_K_M", name: "Good-Fit")
        let tinyLossy = ggufModel(sizeGB: 1.5, quant: "Q2_K", name: "Tiny-Lossy")

        // Precondition: confirm the load plan actually denies the 30 GB model here, so
        // the test exercises the willRun gate rather than a coincidental quality gap.
        XCTAssertFalse(
            scorer.score(wontFit, useCase: .general, device: dev, environment: env)!.willRun,
            "30 GB model on 8 GB device should be denied by ModelLoadPlan"
        )

        let ranked = scorer.rank([wontFit, goodFit, tinyLossy], useCase: .general, device: dev, environment: env)

        XCTAssertEqual(ranked.count, 3)
        // Descending composite.
        for i in 1..<ranked.count {
            XCTAssertGreaterThanOrEqual(
                ranked[i - 1].1.composite, ranked[i].1.composite,
                "rank() must be sorted best-first"
            )
        }
        // The non-runnable model must land last.
        XCTAssertEqual(ranked.last?.0.fileName, "Wont-Fit.Q4_K_M.gguf")
    }

    // MARK: - Edge cases

    func test_zeroSizeModel_returnsNil() {
        let dev = device(ramGB: 8, bandwidthGBs: 100)
        let env = environment(for: dev)
        let model = DownloadableModel(
            repoID: "test/Unknown",
            fileName: "unknown.gguf",
            displayName: "Unknown",
            modelType: .gguf,
            sizeBytes: 0
        )
        XCTAssertNil(
            ModelFitScorer().score(model, useCase: .general, device: dev, environment: env),
            "a zero-size model has nothing to score"
        )
    }

    func test_unknownContextLength_isNeutral() {
        // No knownContextLength → context dimension is the neutral 0.5, never fabricated.
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let env = environment(for: dev)
        let score = ModelFitScorer().score(
            ggufModel(sizeGB: 4.0, quant: "Q4_K_M"),
            useCase: .general,
            device: dev,
            environment: env
        )!
        XCTAssertEqual(score.context, 0.5, accuracy: 0.0001)
    }

    func test_knownContextMeetingNeed_scoresFullContext() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let env = environment(for: dev)
        // chat contextNeed is 4096; supplying 8192 meets it ⇒ context == 1.0.
        let score = ModelFitScorer().score(
            ggufModel(sizeGB: 4.0, quant: "Q4_K_M"),
            useCase: .chat,
            knownContextLength: 8_192,
            device: dev,
            environment: env
        )!
        XCTAssertEqual(score.context, 1.0, accuracy: 0.0001)
    }

    // MARK: - Bandwidth table sanity

    func test_bandwidthTable_ordersChipsByTier() {
        // Relative ordering is what the scorer relies on.
        let base = AppleSiliconBandwidth.bandwidth(forBrandString: "Apple M1")
        let pro = AppleSiliconBandwidth.bandwidth(forBrandString: "Apple M1 Pro")
        let max = AppleSiliconBandwidth.bandwidth(forBrandString: "Apple M1 Max")
        let ultra = AppleSiliconBandwidth.bandwidth(forBrandString: "Apple M1 Ultra")
        XCTAssertLessThan(base, pro)
        XCTAssertLessThan(pro, max)
        XCTAssertLessThan(max, ultra)
    }

    func test_unknownChip_fallsBackConservatively() {
        let bw = AppleSiliconBandwidth.bandwidth(forBrandString: "Intel(R) Core(TM) i9")
        XCTAssertEqual(bw, AppleSiliconBandwidth.fallbackBandwidthGBs)
    }

    func test_quantBits_widerQuantIsHigher() {
        XCTAssertGreaterThan(
            QuantizationBits.bitsPerWeight(for: "Q6_K"),
            QuantizationBits.bitsPerWeight(for: "Q2_K")
        )
        XCTAssertEqual(
            QuantizationBits.bitsPerWeight(for: nil),
            QuantizationBits.neutralBitsPerWeight
        )
    }

    // MARK: - MoE-aware decode speed

    /// A GGUF download with an explicit active-parameter footprint (mixture-of-experts).
    private func moeModel(
        totalGB: Double,
        activeGB: Double,
        quant: String,
        name: String = "MoE"
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: "test/\(name)-GGUF",
            fileName: "\(name).\(quant).gguf",
            displayName: "\(name) \(quant)",
            modelType: .gguf,
            sizeBytes: UInt64(totalGB * Double(oneGB)),
            activeParameterBytes: UInt64(activeGB * Double(oneGB))
        )
    }

    func test_moe_decodesFasterButNotBetterFit_thanDense() {
        // Big device so both models run and the willRun gate doesn't mask the speed math.
        let dev = device(ramGB: 96, bandwidthGBs: 400)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        // MoE: ~60 GB resident, ~10 GB active per token. Dense: ~32 GB, all active.
        // Dense uses a wider quant (Q6) so it reads as higher quality within the shared
        // frontier tier — that quality edge is what reasoning rewards.
        let moe = moeModel(totalGB: 60.0, activeGB: 10.0, quant: "Q4_K_M", name: "Mixtral")
        let dense = ggufModel(sizeGB: 32.0, quant: "Q6_K", name: "Dense")

        let sMoE = scorer.score(moe, useCase: .general, device: dev, environment: env)!
        let sDense = scorer.score(dense, useCase: .general, device: dev, environment: env)!

        // Speed is bound by bytes streamed per token: MoE streams 10 GB, dense streams 32 GB.
        XCTAssertGreaterThan(
            sMoE.speed, sDense.speed,
            "MoE decodes faster: active 10 GB beats dense 32 GB on the same bandwidth"
        )
        XCTAssertGreaterThan(
            sMoE.estimatedTokensPerSecond, sDense.estimatedTokensPerSecond,
            "MoE tok/s should exceed the dense model's"
        )
        // But the MoE is bigger in RAM — its fit must NOT be better than the dense model.
        XCTAssertLessThanOrEqual(
            sMoE.fit, sDense.fit,
            "MoE is bigger in RAM (all experts resident); fit must not improve"
        )

        // Bonus: composite ordering can flip with the use case. chat is speed-weighted
        // (favours the faster MoE); reasoning is quality-weighted (favours the dense,
        // which reads a higher size tier).
        let chatMoE = scorer.score(moe, useCase: .chat, device: dev, environment: env)!
        let chatDense = scorer.score(dense, useCase: .chat, device: dev, environment: env)!
        XCTAssertGreaterThan(
            chatMoE.composite, chatDense.composite,
            "chat (speed-weighted) should prefer the faster MoE"
        )
        let reasonMoE = scorer.score(moe, useCase: .reasoning, device: dev, environment: env)!
        let reasonDense = scorer.score(dense, useCase: .reasoning, device: dev, environment: env)!
        XCTAssertGreaterThan(
            reasonDense.composite, reasonMoE.composite,
            "reasoning (quality-weighted) should prefer the larger dense model"
        )
    }

    func test_nilActiveParameterBytes_matchesSizeBytesDenominator() {
        // A model with nil activeParameterBytes must score the SAME speed/tok-s as an
        // otherwise-identical model whose activeParameterBytes equals its sizeBytes —
        // i.e. the MoE change is a no-op for dense models (no regression).
        let dev = device(ramGB: 32, bandwidthGBs: 200)
        let env = environment(for: dev)
        let scorer = ModelFitScorer()

        let dense = ggufModel(sizeGB: 8.0, quant: "Q4_K_M", name: "Dense")
        let denseExplicit = moeModel(totalGB: 8.0, activeGB: 8.0, quant: "Q4_K_M", name: "Dense")

        let sNil = scorer.score(dense, useCase: .general, device: dev, environment: env)!
        let sExplicit = scorer.score(denseExplicit, useCase: .general, device: dev, environment: env)!

        XCTAssertEqual(sNil.speed, sExplicit.speed, accuracy: 0.0001)
        XCTAssertEqual(
            sNil.estimatedTokensPerSecond, sExplicit.estimatedTokensPerSecond, accuracy: 0.0001
        )
    }

    // MARK: - Apple FM Tier 0 candidate ranking

    /// An OS-resident Apple-FM-style profile.
    private func fmProfile(contextLength: Int? = 8_192) -> ModelSelectionProfile {
        ModelSelectionProfile(
            modelID: "apple.foundation",
            residency: .osResident,
            estimatedFootprintBytes: nil,
            activeParameterBytes: nil,
            contentFiltering: .applied,
            declaredContextLength: contextLength
        )
    }

    func test_fmTier0_available_runsAndRanksAmongRunnable() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let scorer = ModelFitScorer()

        let fm = ModelSelectionCandidate.resident(fmProfile())
        let download = ModelSelectionCandidate.downloadable(
            ggufModel(sizeGB: 4.0, quant: "Q4_K_M", name: "Local")
        )

        let fmScore = scorer.score(candidate: fm, useCase: .chat, device: dev, foundationAvailable: true)!
        XCTAssertTrue(fmScore.willRun, "available Apple FM must be runnable")

        let ranked = scorer.rank(
            candidates: [download, fm], useCase: .chat, device: dev, foundationAvailable: true
        )
        XCTAssertEqual(ranked.count, 2)
        // Both runnable: FM (small active footprint) ranks among them, not collapsed.
        XCTAssertTrue(ranked.allSatisfy { $0.1.willRun }, "both candidates run when FM is available")
    }

    func test_fmTier0_unavailable_sinksBelowEveryRunnable() {
        let dev = device(ramGB: 16, bandwidthGBs: 200)
        let scorer = ModelFitScorer()

        let fm = ModelSelectionCandidate.resident(fmProfile())
        let download = ModelSelectionCandidate.downloadable(
            ggufModel(sizeGB: 4.0, quant: "Q4_K_M", name: "Local")
        )

        let fmScore = scorer.score(candidate: fm, useCase: .chat, device: dev, foundationAvailable: false)!
        XCTAssertFalse(fmScore.willRun, "unavailable Apple FM must not be runnable")

        let ranked = scorer.rank(
            candidates: [fm, download], useCase: .chat, device: dev, foundationAvailable: false
        )
        XCTAssertEqual(ranked.count, 2)
        // The unavailable FM must land last, below the runnable download.
        if case .resident = ranked.last!.0 {
            // expected: FM sank to the bottom
        } else {
            XCTFail("unavailable FM must rank below every runnable candidate")
        }
        XCTAssertFalse(ranked.last!.1.willRun, "the last candidate is the non-runnable FM")
    }
}
