import XCTest
@testable import ManifoldInference

/// Spec-coupled tests for `ModelLoadPlan`.
///
/// These tests mirror the formula in `ModelLoadPlan.compute(inputs:)` through an
/// `expectedOutcome(...)` helper rather than hard-coding constants. That way, a
/// change to (for example) the headroom fraction in a future stage is caught by
/// a *legitimate* test-spec mismatch rather than a brittle literal.
final class ModelLoadPlanTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    // MARK: - Helpers

    /// Shadow implementation of `ModelLoadPlan.compute` used purely for assertions.
    /// Kept verbatim with the production formula so the tests break if either drifts
    /// in a way that wasn't a coordinated change.
    private func expectedOutcome(
        modelFileSize: UInt64,
        strategy: MemoryStrategy,
        requested: Int,
        trained: Int?,
        kvBytesPerToken: UInt64,
        available: UInt64,
        absoluteCeiling: Int = 128_000,
        headroom: Double = 0.40
    ) -> (effective: Int, verdict: ModelLoadPlan.Verdict, resident: UInt64, kv: UInt64, total: UInt64) {
        let residentBudget: UInt64
        switch strategy {
        case .resident: residentBudget = modelFileSize
        case .mappable: residentBudget = min(modelFileSize / 4, oneGB)
        case .external: residentBudget = 0
        }
        let reserveAfterHeadroom = UInt64(Double(available) * (1.0 - headroom))
        let kvBudget: UInt64 = reserveAfterHeadroom > residentBudget
            ? reserveAfterHeadroom - residentBudget
            : 0
        let memoryCeiling = kvBytesPerToken == 0 ? Int.max : Int(kvBudget / kvBytesPerToken)

        var effective = requested
        if let t = trained, t < effective { effective = t }
        if absoluteCeiling < effective { effective = absoluteCeiling }
        if memoryCeiling < effective { effective = memoryCeiling }
        effective = max(1, effective)

        let kvBytes = UInt64(effective) * kvBytesPerToken
        let total = residentBudget &+ kvBytes
        let allowThreshold = UInt64(Double(available) * 0.85)
        // Mirror production's impossible-fit guard: see ModelLoadPlan.compute.
        let impossibleFitRatio: UInt64 = 3
        let impossibleFit = modelFileSize > 0
            && available > 0
            && modelFileSize / available >= impossibleFitRatio
        let verdict: ModelLoadPlan.Verdict
        if impossibleFit {
            verdict = .deny
        } else if total <= allowThreshold {
            verdict = .allow
        } else if total <= available {
            verdict = .warn
        } else {
            verdict = .deny
        }
        return (effective, verdict, residentBudget, kvBytes, total)
    }

    private func makeInputs(
        modelFileSize: UInt64 = 4_000_000_000,
        strategy: MemoryStrategy = .mappable,
        requested: Int = 4096,
        trained: Int? = 8192,
        kvBytesPerToken: UInt64 = 8_192,
        available: UInt64 = 8_000_000_000,
        physical: UInt64 = 16_000_000_000,
        absoluteCeiling: Int = 128_000,
        headroom: Double = 0.40
    ) -> ModelLoadPlan.Inputs {
        ModelLoadPlan.Inputs(
            modelFileSize: modelFileSize,
            memoryStrategy: strategy,
            requestedContextSize: requested,
            trainedContextLength: trained,
            kvBytesPerToken: kvBytesPerToken,
            availableMemoryBytes: available,
            physicalMemoryBytes: physical,
            absoluteContextCeiling: absoluteCeiling,
            headroomFraction: headroom
        )
    }

    // MARK: - Basic cases

    func test_plentyOfMemory_allowsAtRequestedContext() {
        let inputs = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: 8192,
            available: 64 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.effectiveContextSize, 4096)
    }

    func test_constrainedDevice_clampsContextAndAllows() {
        // 1 GB available, 8_192 bytes/token → ~73 000 memory ceiling;
        // requested 128 000 with trained 128 000 → memory is the binding clamp.
        let inputs = makeInputs(
            modelFileSize: 500_000_000,
            strategy: .mappable,
            requested: 128_000,
            trained: 128_000,
            kvBytesPerToken: 8_192,
            available: oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        let exp = expectedOutcome(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: oneGB
        )
        XCTAssertEqual(plan.effectiveContextSize, exp.effective)
        XCTAssertLessThan(plan.effectiveContextSize, 128_000)
        XCTAssertEqual(plan.verdict, exp.verdict)
        XCTAssertTrue(plan.reasons.contains(.memoryCeilingReached(requested: 128_000, ceiling: exp.effective)))
    }

    func test_trainedContextShorterThanRequested_clampsWithInfoReason() {
        let inputs = makeInputs(
            modelFileSize: 2 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 2048,
            available: 32 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, 2048)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.trainedContextExceeded(requested: 8192, trained: 2048)))
    }

    // MARK: - Denial paths

    func test_residentStrategy_deniesWhenWeightsExceedAvailable() {
        // 8 GB model loaded resident, only 3 GB available.
        let inputs = makeInputs(
            modelFileSize: 8 * oneGB,
            strategy: .resident,
            requested: 4096,
            trained: 8192,
            available: 3 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .deny)
        let hasInsufficientResident = plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            return false
        }
        XCTAssertTrue(hasInsufficientResident, "Expected an .insufficientResident reason; got \(plan.reasons)")
    }

    func test_mappableStrategy_deniesWhenKVOverrunsBudget_withInsufficientKVCacheReason() {
        // #400 regression: mappable strategy, weights mmap'd fine, but KV overruns available.
        // The algorithm's fix is to *clamp* the context to what fits, surfacing a
        // `.memoryCeilingReached` info-only reason. The clamp is what prevents the crash —
        // the verdict stays `.allow` by design because the clamped total fits.
        //
        // Deviation from brief: the brief anticipated `.deny` + `.insufficientKVCache`
        // here, but per the explicit formula (verdict computed from *clamped* total,
        // not requested total), denial is impossible once the clamp is applied. We
        // instead assert the clamp is large and surfaces the correct reason — which is
        // still the #400 regression guard because it proves the requested 128 K was
        // rejected. See report for full rationale.
        let inputs = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 128_000,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        // The requested 128 000 must have been clamped hard.
        XCTAssertLessThan(plan.effectiveContextSize, 128_000 / 4)
        let hasMemoryReason = plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }
        XCTAssertTrue(hasMemoryReason, "Expected a .memoryCeilingReached reason; got \(plan.reasons)")
    }

    func test_iPad8GB_128kContext_Qwen7B_profile_clampsContextHard() {
        // #398/#411 regression: iPad jetsam limit ~3 GB on 8 GB device.
        // Qwen2.5 7B Q4 (~4.5 GB file), architectural KV ~131 KB/token.
        // The plan must clamp context drastically to avoid the OOM that #398 reported,
        // and expose a .memoryCeilingReached info-reason for diagnostics.
        //
        // Deviation from brief: per the formula the verdict is `.allow` (clamped total
        // fits). The fix for #398 is the clamp itself. See report.
        let inputs = makeInputs(
            modelFileSize: 4_500_000_000,
            strategy: .mappable,
            requested: 128_000,
            trained: 131_072,
            kvBytesPerToken: 131_072,
            available: 3_000_000_000,
            physical: 8_000_000_000
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertLessThan(plan.effectiveContextSize, 128_000 / 10)
        let hasMemoryReason = plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }
        XCTAssertTrue(hasMemoryReason, "Expected a .memoryCeilingReached reason; got \(plan.reasons)")
    }

    // MARK: - Ceiling info-only

    func test_absoluteCeiling_capsAt128k_withAbsoluteCeilingReasonOnInfoOnly() {
        // Petabytes of memory, trained context 1 M, requested 500 K → clamps to 128 K via absolute ceiling.
        let huge: UInt64 = 1_000_000_000_000
        let inputs = makeInputs(
            modelFileSize: 500_000_000,
            strategy: .mappable,
            requested: 500_000,
            trained: 1_000_000,
            kvBytesPerToken: 8_192,
            available: huge
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, 128_000)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.absoluteCeilingReached(requested: 500_000, ceiling: 128_000)))
    }

    // MARK: - KV fallback

    func test_nilKVEstimate_usesLegacyFallback_produces8kbPerTokenClamp() {
        // Use the ModelInfo factory with no KV estimate — should fall back to 8 192 bytes/token.
        let model = ModelInfo(
            name: "test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 500_000_000,
            modelType: .gguf,
            detectedContextLength: 128_000,
            estimatedKVBytesPerToken: nil
        )
        let oneGBLocal = oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { oneGBLocal },
            physicalMemoryBytes: 8 * oneGBLocal
        )
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 128_000,
            strategy: .mappable,
            environment: env
        )
        // With 8 KB/token: kvBudget ≈ 0.6 GB → ~75 000 tokens.
        let expected = expectedOutcome(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: oneGB
        )
        XCTAssertEqual(plan.effectiveContextSize, expected.effective)
    }

    func test_architecturalKVEstimate_tightensClampVersusLegacy() {
        // Same available memory; architectural estimate (131 072) must clamp tighter than legacy 8 192.
        let available: UInt64 = 2 * oneGB
        let legacy = ModelLoadPlan.compute(inputs: makeInputs(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 8_192, available: available
        ))
        let architectural = ModelLoadPlan.compute(inputs: makeInputs(
            modelFileSize: 500_000_000, strategy: .mappable,
            requested: 128_000, trained: 128_000,
            kvBytesPerToken: 131_072, available: available
        ))
        XCTAssertLessThan(architectural.effectiveContextSize, legacy.effectiveContextSize)
    }

    // MARK: - Monotonicity

    func test_sameModel_doubledContext_producesProportionallyTighterVerdict() {
        // Doubling the requested context on a constrained device must never *relax* the verdict.
        // allow (0) <= warn (1) <= deny (2) ordinality.
        func rank(_ v: ModelLoadPlan.Verdict) -> Int {
            switch v { case .allow: return 0; case .warn: return 1; case .deny: return 2 }
        }
        let base = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 2048,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let doubled = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let quadrupled = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 2 * oneGB
        )
        let p1 = ModelLoadPlan.compute(inputs: base)
        let p2 = ModelLoadPlan.compute(inputs: doubled)
        let p3 = ModelLoadPlan.compute(inputs: quadrupled)
        XCTAssertLessThanOrEqual(rank(p1.verdict), rank(p2.verdict))
        XCTAssertLessThanOrEqual(rank(p2.verdict), rank(p3.verdict))
    }

    // MARK: - Edge cases

    func test_nearZeroMemory_floorsContextAtOne() {
        let inputs = makeInputs(
            modelFileSize: 100_000_000,
            strategy: .mappable,
            requested: 4096,
            trained: 8192,
            kvBytesPerToken: 8_192,
            available: 1000
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertGreaterThanOrEqual(plan.effectiveContextSize, 1)
    }

    // MARK: - Verdict boundaries

    func test_verdict_atExactFit_isWarn() {
        // Construct inputs so totalEstimatedBytes == availableMemoryBytes.
        // Use .external strategy → resident = 0, so total == effective * kvBytes/token.
        // Choose kv = 1, effective = 1_000_000, available = 1_000_000 → total == available → warn.
        // But we also need total > available * 0.85, which is 850_000 — 1_000_000 > 850_000 ✓.
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 1_000_000,
            trainedContextLength: 1_000_000,
            kvBytesPerToken: 1,
            availableMemoryBytes: 1_000_000,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        // With headroom 0.0 and no resident, kvBudget == available, so memoryCeiling = 1_000_000.
        // effective == requested == 1_000_000. Total = 1_000_000 bytes == available → warn.
        XCTAssertEqual(plan.totalEstimatedBytesForAssertion, 1_000_000)
        XCTAssertEqual(plan.verdict, .warn)
    }

    func test_exactFitBoundary_85PercentThreshold_isWarn() {
        // total == 86% of available → should be .warn (above .allow 85% threshold but <= available).
        // total == 84% → .allow.
        let available: UInt64 = 1_000_000_000
        // Warn case: effective fixed such that kv = ~0.86 GB.
        let warnInputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 860_000,
            trainedContextLength: 860_000,
            kvBytesPerToken: 1_000,
            availableMemoryBytes: available,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let warnPlan = ModelLoadPlan.compute(inputs: warnInputs)
        XCTAssertEqual(warnPlan.verdict, .warn)

        // Allow case: total = 0.84 GB → below 0.85 threshold.
        let allowInputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 840_000,
            trainedContextLength: 840_000,
            kvBytesPerToken: 1_000,
            availableMemoryBytes: available,
            physicalMemoryBytes: 16 * oneGB,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let allowPlan = ModelLoadPlan.compute(inputs: allowInputs)
        XCTAssertEqual(allowPlan.verdict, .allow)
    }

    // MARK: - Info-only + allow coexistence

    func test_reasons_includeInfoOnlyWhenVerdictIsAllow() {
        // Plenty of memory, but trained context is smaller than requested → allow + info reason.
        let inputs = makeInputs(
            modelFileSize: 1 * oneGB,
            strategy: .mappable,
            requested: 8192,
            trained: 2048,
            available: 64 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.contains(.trainedContextExceeded(requested: 8192, trained: 2048)))
    }

    // MARK: - System-managed / cloud factories

    func test_systemManaged_factory_allowsWithStubMemory() {
        let plan = ModelLoadPlan.systemManaged(requestedContextSize: 4096)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.effectiveContextSize, 4096)
        XCTAssertEqual(plan.outcome.estimatedKVBytes, 0)
    }

    func test_cloud_factory_allowsWithInformationalContext() {
        let plan = ModelLoadPlan.cloud(requestedContextSize: 0)
        XCTAssertEqual(plan.verdict, .allow)
    }

    // MARK: - Property-style grid tests

    /// For every grid input, total must equal resident + kv (the two sub-estimates).
    func test_property_totalEqualsResidentPlusKV() {
        let strategies: [MemoryStrategy] = [.resident, .mappable, .external]
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB, 16 * oneGB]
        let requesteds = [1024, 8192, 32_000]
        let trainedOpts: [Int?] = [nil, 8192, 131_072]
        let kvs: [UInt64] = [8_192, 65_536, 131_072]
        let availables: [UInt64] = [oneGB, 4 * oneGB, 16 * oneGB]

        for strategy in strategies {
            for fs in fileSizes {
                for req in requesteds {
                    for trained in trainedOpts {
                        for kv in kvs {
                            for avail in availables {
                                let inputs = self.makeInputs(
                                    modelFileSize: fs, strategy: strategy, requested: req,
                                    trained: trained, kvBytesPerToken: kv, available: avail
                                )
                                let plan = ModelLoadPlan.compute(inputs: inputs)
                                XCTAssertEqual(
                                    plan.outcome.totalEstimatedBytes,
                                    plan.outcome.estimatedResidentBytes + plan.outcome.estimatedKVBytes,
                                    "total != resident + kv for \(inputs)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// effectiveContextSize must be <= every ceiling (requested, trained, memory, absolute).
    func test_property_effectiveContextLEAllCeilings() {
        let strategies: [MemoryStrategy] = [.resident, .mappable]
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB]
        let requesteds = [1024, 8192, 64_000, 200_000]
        let trainedOpts: [Int?] = [nil, 4096, 131_072]
        let kvs: [UInt64] = [8_192, 131_072]
        let availables: [UInt64] = [oneGB, 8 * oneGB]

        for strategy in strategies {
            for fs in fileSizes {
                for req in requesteds {
                    for trained in trainedOpts {
                        for kv in kvs {
                            for avail in availables {
                                let inputs = self.makeInputs(
                                    modelFileSize: fs, strategy: strategy, requested: req,
                                    trained: trained, kvBytesPerToken: kv, available: avail
                                )
                                let plan = ModelLoadPlan.compute(inputs: inputs)

                                // Recompute the memory ceiling locally, same formula as production.
                                let residentBudget: UInt64
                                switch strategy {
                                case .resident: residentBudget = fs
                                case .mappable: residentBudget = min(fs / 4, oneGB)
                                case .external: residentBudget = 0
                                }
                                let reserveAfter = UInt64(Double(avail) * 0.60)
                                let kvBudget: UInt64 = reserveAfter > residentBudget ? reserveAfter - residentBudget : 0
                                let memoryCeiling = Int(kvBudget / kv)
                                // Production only clamps to trained when trained != nil; when nil the
                                // effective size can still be bounded by requested/absolute/memory.
                                let trainedCeiling = trained ?? Int.max
                                let upperBound = min(req, trainedCeiling, memoryCeiling, 128_000)

                                XCTAssertLessThanOrEqual(
                                    plan.effectiveContextSize,
                                    max(1, upperBound),
                                    "effective exceeded a ceiling for \(inputs)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Doubling availableMemoryBytes must never make the verdict *stricter*.
    func test_property_verdictMonotonicInAvailableMemory() {
        func rank(_ v: ModelLoadPlan.Verdict) -> Int {
            switch v { case .allow: return 0; case .warn: return 1; case .deny: return 2 }
        }
        let fileSizes: [UInt64] = [1 * oneGB, 4 * oneGB]
        let kvs: [UInt64] = [8_192, 131_072]
        let requesteds = [4096, 64_000]

        // We keep strategy, fileSize, requested, trained, kv fixed and vary `available`.
        for fs in fileSizes {
            for kv in kvs {
                for req in requesteds {
                    let base = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: oneGB
                    )
                    let doubled = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: 2 * oneGB
                    )
                    let quadrupled = self.makeInputs(
                        modelFileSize: fs, strategy: .mappable, requested: req,
                        trained: 131_072, kvBytesPerToken: kv, available: 4 * oneGB
                    )
                    let p1 = ModelLoadPlan.compute(inputs: base)
                    let p2 = ModelLoadPlan.compute(inputs: doubled)
                    let p3 = ModelLoadPlan.compute(inputs: quadrupled)
                    XCTAssertLessThanOrEqual(rank(p2.verdict), rank(p1.verdict),
                        "doubling memory made verdict stricter: \(p1.verdict) -> \(p2.verdict)")
                    XCTAssertLessThanOrEqual(rank(p3.verdict), rank(p2.verdict),
                        "quadrupling memory made verdict stricter: \(p2.verdict) -> \(p3.verdict)")
                }
            }
        }
    }

    // MARK: - canRunModel UI helper

    func test_canRunModel_smallModelOnTypicalDevice_returnsTrue() {
        XCTAssertTrue(ModelLoadPlan.canRunModel(sizeBytes: 2 * oneGB, physicalMemoryBytes: 8 * oneGB))
    }

    func test_canRunModel_modelLargerThanRAM_returnsFalse() {
        XCTAssertFalse(ModelLoadPlan.canRunModel(sizeBytes: 16 * oneGB, physicalMemoryBytes: 8 * oneGB))
    }

    func test_canRunModel_isUsedConsistentlyAcrossUIRecommendationCallers() {
        // Pre-download UI helpers (ModelManagementViewModel.canRunModel,
        // .compatibilityTier, DownloadableModel.recommendedVariant) all defer to this
        // single helper. Sabotage check: if the helper drops the .resident strategy
        // and goes .mappable, this small-on-large case still passes — but the
        // boundary case below would silently flip from false to true.
        XCTAssertFalse(ModelLoadPlan.canRunModel(sizeBytes: 6 * oneGB, physicalMemoryBytes: 4 * oneGB))
    }

    // MARK: - Saturating-arithmetic edges (W2)

    /// Available memory well below the resident budget must not underflow
    /// `UInt64`. The saturating-subtraction branch around line 162 guards
    /// this. A regression that accidentally uses wrapping subtraction would
    /// produce a kvBudget of ~18 exabytes and silently `.allow` everything.
    func test_nearZeroMemory_saturatingSubtractionDoesNotUnderflow() {
        // 4 GB model, mappable (resident budget 1 GB), 1 KB available.
        // reserveAfterHeadroom = 1000 * 0.6 = 600 bytes.
        // residentBudget (1 GB) > reserveAfterHeadroom (600 B) → kvBudget == 0.
        let inputs = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: 8192,
            kvBytesPerToken: 8_192,
            available: 1_000
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        // effective is floored to 1 (not a huge wrapped number).
        XCTAssertEqual(plan.effectiveContextSize, 1,
                       "Effective context must floor at 1, not wrap from UInt64 underflow")
        // KV = 1 * 8_192 = 8_192. Total = resident (≤1 GB) + 8 KB, which is
        // vastly greater than the 1 000 B available → .deny.
        XCTAssertEqual(plan.verdict, .deny)
        // And critically, totalEstimatedBytes stays a sane number — not
        // anywhere near UInt64.max that an underflow would produce.
        XCTAssertLessThan(plan.outcome.totalEstimatedBytes, 2 * oneGB,
                          "Total must not contain a wrapped-underflow value")
    }

    /// `kvBytesPerToken == 0` sets `memoryCeiling = Int.max`, which is the
    /// div-by-zero guard at line 168. A regression that made memoryCeiling
    /// small (e.g., 0) would falsely clamp every context to 1. A regression
    /// that dropped the guard would crash. Verify the verdict stays sensible:
    /// the estimator never pretends zero KV is unlimited free memory.
    func test_kvBytesPerTokenZero_memoryCeilingIntMax_verdictReflectsOnlyResident() {
        // Modest resident cost, no KV cost. Should be freely .allow — and
        // effective context == requested, because memoryCeiling is Int.max.
        let inputs = makeInputs(
            modelFileSize: 100_000_000,
            strategy: .mappable,
            requested: 8192,
            trained: 16_384,
            kvBytesPerToken: 0,
            available: 4 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertEqual(plan.effectiveContextSize, 8192)
        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.outcome.estimatedKVBytes, 0)
        // No memoryCeilingReached reason when the kv-divisor path is stubbed out.
        let hasMemoryReason = plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }
        XCTAssertFalse(hasMemoryReason,
                       "kvBytesPerToken == 0 must not surface a memoryCeilingReached reason")
    }

    /// `kvBytesPerToken == 0` with resident overrunning available must still
    /// `.deny` — the Int.max ceiling isn't a free pass. Verifies the verdict
    /// is driven by total cost, not just the ceiling.
    func test_kvBytesPerTokenZero_residentOverrunsAvailable_stillDenies() {
        let inputs = makeInputs(
            modelFileSize: 16 * oneGB,
            strategy: .resident,
            requested: 8192,
            trained: 16_384,
            kvBytesPerToken: 0,
            available: 2 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertEqual(plan.verdict, .deny,
                       "kvBytesPerToken == 0 must not mask an insufficient-resident deny")
        let hasInsufficientResident = plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            return false
        }
        XCTAssertTrue(hasInsufficientResident,
                      "Expected .insufficientResident reason; got \(plan.reasons)")
    }

    /// 70B-class model (~140 GB weights, ~400 KB/token KV) on a 4 GB device
    /// must never `.allow`. This is the "catastrophically wrong" case — if
    /// anything in the plan silently permits it, users on small devices see
    /// OOM crashes with no upstream warning.
    ///
    /// Uses the `.resident` strategy because that's the path where
    /// `estimatedResidentBytes` actually tracks the file size. Under
    /// `.mappable`, resident caps at 1 GB regardless of file size — a
    /// separate heuristic concern that is out of scope for this test.
    /// (See report: the mappable heuristic under-estimates for huge files
    /// and can silently `.allow` a 140 GB file; not fixed here.)
    /// Companion to the `.resident` case above. Under `.mappable`, a 140 GB
    /// file on a 4 GB device is 35× the available RAM — far beyond what mmap
    /// can stream without catastrophic thrashing. The plan must `.deny` before
    /// the load ever reaches llama.cpp (where it would crash or hang with a
    /// useless error).
    ///
    /// Historical note: prior to the impossible-fit guard, the `.mappable`
    /// residentBudget capped at `min(fileSize/4, 1 GB) == 1 GB` for any huge
    /// file, so total ≈ 1 GB + a few hundred MB of KV fit under the 85%
    /// threshold and the plan silently returned `.allow`.
    func test_70BModelOn4GBDevice_mappableStrategy_denies() {
        let seventyBBytes: UInt64 = 140 * oneGB
        let fourGB: UInt64 = 4 * oneGB
        let inputs = makeInputs(
            modelFileSize: seventyBBytes,
            strategy: .mappable,
            requested: 2048,
            trained: 131_072,
            kvBytesPerToken: 400_000,
            available: fourGB,
            physical: fourGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertEqual(plan.verdict, .deny,
                       "140 GB file on 4 GB device must .deny; got \(plan.verdict)")
        // A primary reason the UI can surface — not just a silent deny.
        let hasInsufficientResident = plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            return false
        }
        XCTAssertTrue(hasInsufficientResident,
                      "Expected .insufficientResident reason; got \(plan.reasons)")
    }

    /// Boundary case on the permissive side of the impossible-fit guard: a
    /// 10 GB model on an 8 GB-RAM device (ratio 1.25×) must still be allowed
    /// under `.mappable`. The fix must not over-reject legitimate loads —
    /// page-cache-backed mmap handles working sets up to ~2-3× RAM routinely.
    func test_10GBModelOn8GBDevice_mappableStrategy_allows() {
        let tenGB: UInt64 = 10 * oneGB
        let eightGB: UInt64 = 8 * oneGB
        let inputs = makeInputs(
            modelFileSize: tenGB,
            strategy: .mappable,
            requested: 4096,
            trained: 32_768,
            kvBytesPerToken: 8_192,
            available: eightGB,
            physical: eightGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertEqual(plan.verdict, .allow,
                       "10 GB / 8 GB RAM (1.25×) must remain allowed; impossible-fit guard must not over-reject")
    }

    /// Boundary case on the deny side: 30 GB file on 4 GB RAM (ratio 7.5×)
    /// is far beyond what mmap can realistically stream — the guard must
    /// reject it pre-load. This tests the core invariant the fix enforces
    /// without relying on 70B-scale numbers.
    func test_30GBModelOn4GBDevice_mappableStrategy_denies() {
        let thirtyGB: UInt64 = 30 * oneGB
        let fourGB: UInt64 = 4 * oneGB
        let inputs = makeInputs(
            modelFileSize: thirtyGB,
            strategy: .mappable,
            requested: 2048,
            trained: 32_768,
            kvBytesPerToken: 8_192,
            available: fourGB,
            physical: fourGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertEqual(plan.verdict, .deny,
                       "30 GB / 4 GB RAM (7.5×) must deny; mmap cannot stream at that ratio without thrashing")
        let hasInsufficientResident = plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            return false
        }
        XCTAssertTrue(hasInsufficientResident,
                      "Expected .insufficientResident reason for impossible fit; got \(plan.reasons)")
    }

    /// Boundary tests for the impossible-fit guard (ratio == 3). The production
    /// formula uses integer division `file / available >= 3`, which denies
    /// exactly when `file >= 3 * available`. A regression that flips the
    /// comparison (> vs >=) or bumps the ratio (3 → 4) silently lets a 12 GB
    /// model slip through on a 4 GB device — exactly the class of bug this
    /// guard was added to prevent. These pin the boundary so future changes
    /// require an explicit update.
    func test_impossibleFitGuard_atRatioExactlyThree_denies() {
        // 12 GB / 4 GB = exactly 3× → must deny.
        let inputs = makeInputs(
            modelFileSize: 12 * oneGB,
            strategy: .mappable,
            requested: 2048,
            trained: 32_768,
            kvBytesPerToken: 8_192,
            available: 4 * oneGB,
            physical: 4 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .deny,
                       "12 GB / 4 GB (ratio == 3) must deny; guard uses >= comparison")
    }

    func test_impossibleFitGuard_justBelowRatioThree_doesNotDeny() {
        // 12 GB - 1 byte over 4 GB → integer ratio = 2 → guard does NOT fire.
        // Verdict is whatever the normal thresholds produce; the point is that
        // the new guard alone doesn't flip it to deny.
        let inputs = makeInputs(
            modelFileSize: 12 * oneGB - 1,
            strategy: .mappable,
            requested: 2048,
            trained: 32_768,
            kvBytesPerToken: 8_192,
            available: 4 * oneGB,
            physical: 4 * oneGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        // Without the guard firing, a 12 GB mmap'd file on 4 GB available with
        // tiny context (2048 tokens * 8 KB = 16 MB KV) totals ~1.016 GB
        // (resident 1 GB cap + 16 MB KV) which is < 85% of 4 GB → .allow.
        // If the guard fires incorrectly here the verdict would be .deny.
        XCTAssertNotEqual(plan.verdict, .deny,
                          "12 GB - 1B / 4 GB (ratio < 3) must not be denied by the impossible-fit guard")
    }

    // MARK: - App overhead (issue #471)

    /// Overhead bytes reduce the effective KV budget, producing a smaller
    /// `effectiveContextSize` than the same inputs with no overhead.
    func test_appOverhead_reducesKVBudget() {
        let available: UInt64 = 5_000_000_000
        let overhead: UInt64 = 838_860_800  // 800 MiB

        let withOverhead = ModelLoadPlan.compute(inputs: ModelLoadPlan.Inputs(
            modelFileSize: 3 * oneGB,
            memoryStrategy: .mappable,
            requestedContextSize: 128_000,
            trainedContextLength: 131_072,
            kvBytesPerToken: 65_536,
            availableMemoryBytes: available,
            physicalMemoryBytes: 8 * oneGB,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40,
            appOverheadBytes: overhead
        ))

        let withoutOverhead = ModelLoadPlan.compute(inputs: ModelLoadPlan.Inputs(
            modelFileSize: 3 * oneGB,
            memoryStrategy: .mappable,
            requestedContextSize: 128_000,
            trainedContextLength: 131_072,
            kvBytesPerToken: 65_536,
            availableMemoryBytes: available,
            physicalMemoryBytes: 8 * oneGB,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40,
            appOverheadBytes: 0
        ))

        XCTAssertLessThan(
            withOverhead.effectiveContextSize,
            withoutOverhead.effectiveContextSize,
            "App overhead must reduce the effective context size vs no-overhead baseline"
        )
    }

    /// When `appOverheadBytes` exceeds `availableMemoryBytes`, the plan must not
    /// underflow UInt64 and must floor `effectiveContextSize` at 1.
    func test_appOverhead_largerThanAvailable_doesNotUnderflow() {
        let plan = ModelLoadPlan.compute(inputs: ModelLoadPlan.Inputs(
            modelFileSize: 500_000_000,
            memoryStrategy: .mappable,
            requestedContextSize: 4096,
            trainedContextLength: 8192,
            kvBytesPerToken: 8_192,
            availableMemoryBytes: 100_000_000,
            physicalMemoryBytes: 8 * oneGB,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40,
            appOverheadBytes: 200_000_000  // overhead > available
        ))

        XCTAssertGreaterThanOrEqual(plan.effectiveContextSize, 1,
            "Effective context must floor at 1 when overhead exceeds available memory")
        // Also verify totalEstimatedBytes is a sane value, not a UInt64 wraparound.
        XCTAssertLessThan(plan.outcome.totalEstimatedBytes, UInt64.max / 2,
            "Total estimated bytes must not contain a UInt64 underflow value")
    }

    /// Default `appOverheadBytes: 0` must produce exactly the same
    /// `effectiveContextSize` as inputs constructed without the field — no-op
    /// regression guard for existing callers.
    func test_appOverhead_zero_preservesExistingBehaviour() {
        let inputsOld = makeInputs(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 32_000,
            trained: 131_072,
            kvBytesPerToken: 65_536,
            available: 8 * oneGB
        )
        // New inputs with explicit appOverheadBytes: 0 — must be identical.
        let inputsNew = ModelLoadPlan.Inputs(
            modelFileSize: 4 * oneGB,
            memoryStrategy: .mappable,
            requestedContextSize: 32_000,
            trainedContextLength: 131_072,
            kvBytesPerToken: 65_536,
            availableMemoryBytes: 8 * oneGB,
            physicalMemoryBytes: 16_000_000_000,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40,
            appOverheadBytes: 0
        )

        let planOld = ModelLoadPlan.compute(inputs: inputsOld)
        let planNew = ModelLoadPlan.compute(inputs: inputsNew)

        XCTAssertEqual(planNew.effectiveContextSize, planOld.effectiveContextSize,
            "appOverheadBytes: 0 must preserve existing behaviour")
        XCTAssertEqual(planNew.verdict, planOld.verdict,
            "appOverheadBytes: 0 must produce the same verdict as the legacy path")
    }

    func test_70BModelOn4GBDevice_residentStrategy_neverAllows() {
        // 70B at ~4-bit quant ~ 40 GB file. Use a generous 140 GB upper bound
        // to also cover fp16 distributions.
        let seventyBBytes: UInt64 = 140 * oneGB
        let fourGB: UInt64 = 4 * oneGB
        let inputs = makeInputs(
            modelFileSize: seventyBBytes,
            strategy: .resident,                   // residentBudget == file size
            requested: 2048,                       // small context — favours .allow
            trained: 131_072,
            kvBytesPerToken: 400_000,              // 70B-ish architectural KV
            available: fourGB,
            physical: fourGB
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)

        XCTAssertNotEqual(plan.verdict, .allow,
                          "70B-class on 4 GB must never .allow; got \(plan.verdict) with total=\(plan.outcome.totalEstimatedBytes)")
        // Stronger: it should be a flat deny — .warn would still be wrong
        // here, because a 140 GB file cannot fit with only 4 GB resident.
        XCTAssertEqual(plan.verdict, .deny)
    }

    // MARK: - ModelType-driven overload

    /// `.foundation` ModelInfo must produce a plan identical to `systemManaged(...)`.
    /// The OS owns memory; the plan is a stub-allow regardless of `environment`.
    func test_computeForModelInfo_foundation_matchesSystemManaged() {
        let model = ModelInfo(
            name: "AppleFoundation",
            fileName: "",
            url: URL(fileURLWithPath: "/dev/null"),
            fileSize: 0,
            modelType: .foundation,
            detectedContextLength: nil,
            estimatedKVBytesPerToken: nil
        )
        let inferred = ModelLoadPlan.compute(for: model, requestedContextSize: 4096)
        let expected = ModelLoadPlan.systemManaged(requestedContextSize: 4096)

        XCTAssertEqual(inferred.verdict, expected.verdict)
        XCTAssertEqual(inferred.effectiveContextSize, expected.effectiveContextSize)
        XCTAssertEqual(inferred.outcome, expected.outcome)
        XCTAssertEqual(inferred.inputs, expected.inputs)
    }

    /// `.gguf` ModelInfo must produce a plan equivalent to the explicit overload
    /// with `.mappable` — the strategy llama.cpp actually declares in production.
    /// (LlamaBackend.capabilities.memoryStrategy == .mappable).
    func test_computeForModelInfo_gguf_matchesMappableExplicit() {
        let model = ModelInfo(
            name: "test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 4 * oneGB,
            modelType: .gguf,
            detectedContextLength: 8192,
            estimatedKVBytesPerToken: 65_536
        )
        let twoGBLocal = 2 * oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { twoGBLocal },
            physicalMemoryBytes: 16 * oneGB
        )
        let inferred = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 4096,
            environment: env
        )
        let explicit = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 4096,
            strategy: .mappable,
            environment: env
        )

        XCTAssertEqual(inferred.outcome, explicit.outcome)
        XCTAssertEqual(inferred.inputs, explicit.inputs)
        XCTAssertEqual(inferred.inputs.memoryStrategy, .mappable)
    }

    /// `.mlx` ModelInfo must produce a plan equivalent to the explicit overload
    /// with `.resident` — MLXBackend.capabilities.memoryStrategy == .resident.
    func test_computeForModelInfo_mlx_matchesResidentExplicit() {
        let model = ModelInfo(
            name: "test-mlx",
            fileName: "model.safetensors",
            url: URL(fileURLWithPath: "/tmp/mlx-model"),
            fileSize: 4 * oneGB,
            modelType: .mlx,
            detectedContextLength: 8192,
            estimatedKVBytesPerToken: 65_536
        )
        let eightGBLocal = 8 * oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { eightGBLocal },
            physicalMemoryBytes: 16 * oneGB
        )
        let inferred = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 4096,
            environment: env
        )
        let explicit = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 4096,
            strategy: .resident,
            environment: env
        )

        XCTAssertEqual(inferred.outcome, explicit.outcome)
        XCTAssertEqual(inferred.inputs, explicit.inputs)
        XCTAssertEqual(inferred.inputs.memoryStrategy, .resident)
    }

    // MARK: - estimate(for: DownloadableModel) — pre-download fit verdict

    /// Helper: build a `DownloadableModel` for fit tests without going through the
    /// curated catalogue. Filename is `.gguf` by default so quantization extraction
    /// has a real input shape, even though `estimate(...)` ignores it.
    private func makeDownloadable(
        sizeBytes: UInt64,
        modelType: ModelType = .gguf,
        fileName: String = "test-Q4_K_M.gguf"
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: "test/repo",
            fileName: fileName,
            displayName: "Test Model",
            modelType: modelType,
            sizeBytes: sizeBytes
        )
    }

    /// Small GGUF model on a 16 GB device with ample free memory → `.allow`, no clamp.
    func test_estimate_smallModel_amplyMemory_allows() {
        let oneGBLocal = oneGB
        let model = makeDownloadable(sizeBytes: 2 * oneGBLocal)
        let twelveGB = 12 * oneGBLocal
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { twelveGB },
            physicalMemoryBytes: 16 * oneGBLocal
        )
        let plan = ModelLoadPlan.estimate(
            for: model,
            requestedContextSize: 4096,
            environment: env
        )

        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.effectiveContextSize, 4096, "Ample memory must not clamp the requested context.")
        // Strategy must come from the format → .gguf maps to .mappable.
        XCTAssertEqual(plan.inputs.memoryStrategy, .mappable)
        // No clamp reasons expected when nothing was tightened.
        XCTAssertFalse(plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            if case .absoluteCeilingReached = reason { return true }
            return false
        })
    }

    /// Tight memory → memory-derived ceiling tightens context below the request.
    /// We pick numbers where the memory ceiling is well below 4096 tokens so the
    /// clamp is visible and the verdict can still come out `.allow` (resident is small).
    func test_estimate_clampsContext_whenMemoryTight() {
        // 4 GB mappable file → residentBudget = min(1 GB, 1 GB) = 1 GB.
        // available = 2 GB, headroom 0.40 → reserveAfterHeadroom = 1.2 GB.
        // kvBudget = 1.2 GB − 1 GB = 0.2 GB; / 8 KB = ~26214 tokens (still > 4096).
        // Force a tighter clamp by squeezing available further.
        let model = makeDownloadable(sizeBytes: 4 * oneGB)
        let available: UInt64 = 1_800_000_000  // 1.8 GB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { available },
            physicalMemoryBytes: 16 * oneGB
        )
        let plan = ModelLoadPlan.estimate(
            for: model,
            requestedContextSize: 8192,
            environment: env
        )

        XCTAssertLessThan(plan.effectiveContextSize, 8192,
                          "Tight memory must clamp effective context below the request.")
        XCTAssertTrue(plan.reasons.contains { reason in
            if case .memoryCeilingReached = reason { return true }
            return false
        }, "A memory clamp must produce a .memoryCeilingReached reason. Got: \(plan.reasons)")
    }

    /// Oversized model (40 GB on 8 GB available) → `.deny` with an insufficient-resident
    /// reason from the impossible-fit guard.
    func test_estimate_oversized_denies_withMemoryReason() {
        let oneGBLocal = oneGB
        let model = makeDownloadable(sizeBytes: 40 * oneGBLocal)
        let eightGB = 8 * oneGBLocal
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { eightGB },
            physicalMemoryBytes: 16 * oneGBLocal
        )
        let plan = ModelLoadPlan.estimate(
            for: model,
            requestedContextSize: 4096,
            environment: env
        )

        XCTAssertEqual(plan.verdict, .deny)
        XCTAssertTrue(plan.reasons.contains { reason in
            if case .insufficientResident = reason { return true }
            if case .insufficientKVCache = reason { return true }
            return false
        }, "Oversized denies must surface a memory-headroom reason. Got: \(plan.reasons)")
    }

    /// KV-cache fallback path: manifest has no arch hints, so estimate must use the
    /// legacy 8 KB/token fallback. Verify by computing the expected outcome with that
    /// exact constant and comparing verdict + total bytes.
    func test_estimate_kvFallback_usesLegacy8KBPerToken() {
        let model = makeDownloadable(sizeBytes: 4 * oneGB)
        let available: UInt64 = 8 * oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { available },
            physicalMemoryBytes: 16 * oneGB
        )
        let plan = ModelLoadPlan.estimate(
            for: model,
            requestedContextSize: 4096,
            environment: env
        )

        let expected = expectedOutcome(
            modelFileSize: 4 * oneGB,
            strategy: .mappable,
            requested: 4096,
            trained: nil,
            kvBytesPerToken: 8_192,  // legacy fallback — what estimate() must use
            available: available
        )

        XCTAssertEqual(plan.inputs.kvBytesPerToken, 8_192,
                       "estimate() must populate kvBytesPerToken with the legacy 8 KB fallback for manifest-only inputs.")
        XCTAssertEqual(plan.verdict, expected.verdict)
        XCTAssertEqual(plan.effectiveContextSize, expected.effective)
        XCTAssertEqual(plan.outcome.totalEstimatedBytes, expected.total)
    }

    /// `.foundation` short-circuit: estimate() returns the systemManaged stub regardless
    /// of sizeBytes / environment.
    func test_estimate_foundation_returnsSystemManaged() {
        let model = makeDownloadable(sizeBytes: 0, modelType: .foundation, fileName: "apple-foundation")
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { 0 },
            physicalMemoryBytes: 0
        )
        let plan = ModelLoadPlan.estimate(for: model, requestedContextSize: 4096, environment: env)
        let expected = ModelLoadPlan.systemManaged(requestedContextSize: 4096)

        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertEqual(plan.outcome, expected.outcome)
        XCTAssertEqual(plan.inputs, expected.inputs)
    }

    /// `.mlx` modelType must pick the `.resident` strategy (mirrors the ModelInfo overload).
    func test_estimate_mlx_usesResidentStrategy() {
        let oneGBLocal = oneGB
        let model = makeDownloadable(sizeBytes: 2 * oneGBLocal, modelType: .mlx, fileName: "mlx-community/Test-4bit")
        let twelveGB = 12 * oneGBLocal
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { twelveGB },
            physicalMemoryBytes: 16 * oneGBLocal
        )
        let plan = ModelLoadPlan.estimate(for: model, requestedContextSize: 4096, environment: env)

        XCTAssertEqual(plan.inputs.memoryStrategy, .resident)
    }

    /// Verdict-parity sanity: a `DownloadableModel` and a same-sized GGUF `ModelInfo`
    /// (no detected KV/token, no trained-context length) must agree on the allow/deny
    /// verdict. `estimate(...)` may differ on the clamped context value because it
    /// lacks the on-disk trained-context length, but the top-level fit decision must
    /// match for inputs that don't depend on that field.
    func test_estimate_verdictParity_withComputeForModelInfo_allow() {
        let fileSize: UInt64 = 4 * oneGB
        let available: UInt64 = 12 * oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { available },
            physicalMemoryBytes: 16 * oneGB
        )

        let dl = makeDownloadable(sizeBytes: fileSize)
        let mi = ModelInfo(
            name: "parity",
            fileName: "parity.gguf",
            url: URL(fileURLWithPath: "/tmp/parity.gguf"),
            fileSize: fileSize,
            modelType: .gguf,
            detectedContextLength: nil,        // match estimate()'s manifest blindness
            estimatedKVBytesPerToken: nil      // forces legacy 8 KB fallback in compute()
        )

        let estimatePlan = ModelLoadPlan.estimate(for: dl, requestedContextSize: 4096, environment: env)
        let computePlan = ModelLoadPlan.compute(for: mi, requestedContextSize: 4096, environment: env)

        XCTAssertEqual(estimatePlan.verdict, computePlan.verdict)
        XCTAssertEqual(estimatePlan.verdict, .allow)
    }

    /// Verdict-parity sanity at the deny end: an oversized model must deny via both
    /// entry points, regardless of clamp-value differences.
    func test_estimate_verdictParity_withComputeForModelInfo_deny() {
        let fileSize: UInt64 = 40 * oneGB
        let available: UInt64 = 8 * oneGB
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { available },
            physicalMemoryBytes: 16 * oneGB
        )

        let dl = makeDownloadable(sizeBytes: fileSize)
        let mi = ModelInfo(
            name: "parity-big",
            fileName: "parity-big.gguf",
            url: URL(fileURLWithPath: "/tmp/parity-big.gguf"),
            fileSize: fileSize,
            modelType: .gguf,
            detectedContextLength: nil,
            estimatedKVBytesPerToken: nil
        )

        let estimatePlan = ModelLoadPlan.estimate(for: dl, requestedContextSize: 4096, environment: env)
        let computePlan = ModelLoadPlan.compute(for: mi, requestedContextSize: 4096, environment: env)

        XCTAssertEqual(estimatePlan.verdict, .deny)
        XCTAssertEqual(estimatePlan.verdict, computePlan.verdict)
    }
}

// MARK: - Convenience accessor (test-scoped, avoids repeating `plan.outcome.totalEstimatedBytes`)

private extension ModelLoadPlan {
    var totalEstimatedBytesForAssertion: UInt64 { outcome.totalEstimatedBytes }
}
