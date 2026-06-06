import Foundation

// MARK: - Device Profile

/// A snapshot of the host device's memory characteristics used by `ModelFitScorer`
/// to derive the speed dimension.
///
/// `memoryBandwidthGBs` is the dominant term for local-LLM decode throughput:
/// autoregressive generation is memory-bandwidth bound (every token streams the
/// full weight set through the memory bus), so tokens/sec scales roughly with
/// bandwidth ÷ model footprint. We surface bandwidth here rather than recomputing
/// it inside the scorer so tests can inject hypothetical devices.
public struct DeviceProfile: Sendable, Equatable {
    /// Total physical RAM (`ProcessInfo.physicalMemory`).
    public let physicalMemoryBytes: UInt64
    /// Memory available for allocation (jetsam budget on iOS, physical on macOS).
    public let usableMemoryBytes: UInt64
    /// Approximate unified-memory bandwidth in GB/s. See `AppleSiliconBandwidth`
    /// for the source table and its caveats (figures are published approximations;
    /// unknown chips fall back conservatively).
    public let memoryBandwidthGBs: Double

    public init(
        physicalMemoryBytes: UInt64,
        usableMemoryBytes: UInt64,
        memoryBandwidthGBs: Double
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.usableMemoryBytes = usableMemoryBytes
        self.memoryBandwidthGBs = memoryBandwidthGBs
    }

    /// The real host device. Reads physical/usable memory from the system and
    /// estimates bandwidth from the detected chip.
    public static var current: DeviceProfile {
        DeviceProfile(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            usableMemoryBytes: DeviceCapabilityService.queryAvailableMemory(),
            memoryBandwidthGBs: AppleSiliconBandwidth.estimatedBandwidthGBs()
        )
    }
}

// MARK: - Apple Silicon Bandwidth Table

/// Maps the host chip to an approximate unified-memory bandwidth (GB/s).
///
/// ## Why a table
/// There is no public runtime API that reports memory bandwidth. The figures
/// below are Apple's published per-chip numbers (Apple Newsroom / Tech specs).
/// They are approximations — binned SKUs of the same chip can differ (e.g. the
/// base M3 Max ships in 300 and 400 GB/s variants), and we cannot distinguish the
/// bin at runtime, so we pick a representative value and document it. The scorer
/// only uses bandwidth to *rank* candidates, so the relative ordering matters far
/// more than absolute precision.
///
/// ## Detection
/// - macOS: `sysctlbyname("machdep.cpu.brand_string")` returns e.g. "Apple M1 Pro".
/// - iOS/visionOS: that sysctl is restricted, so we map the `hw.machine` device
///   identifier (e.g. "iPhone16,1") to a conservative A-/M-series figure.
/// - Unknown chip → a deliberately conservative `fallbackBandwidthGBs`.
public enum AppleSiliconBandwidth {

    /// Conservative fallback for chips we can't identify (older Intel Macs, future
    /// silicon, restricted environments). Picked low on purpose: an unknown device
    /// should not be ranked as if it had flagship bandwidth.
    public static let fallbackBandwidthGBs: Double = 50.0

    /// Returns the estimated bandwidth for the current host device.
    public static func estimatedBandwidthGBs() -> Double {
        #if os(macOS)
        if let brand = cpuBrandString() {
            return bandwidth(forBrandString: brand)
        }
        return fallbackBandwidthGBs
        #elseif os(iOS) || os(visionOS)
        if let machine = machineIdentifier() {
            return bandwidth(forIOSMachine: machine)
        }
        return fallbackBandwidthGBs
        #else
        return fallbackBandwidthGBs
        #endif
    }

    // MARK: Brand-string mapping (macOS / Apple Silicon)

    /// Maps an Apple Silicon CPU brand string ("Apple M3 Max") to GB/s.
    ///
    /// Published figures (GB/s):
    /// M1 68 · M1 Pro 200 · M1 Max 400 · M1 Ultra 800;
    /// M2 100 · M2 Pro 200 · M2 Max 400 · M2 Ultra 800;
    /// M3 100 · M3 Pro 150 · M3 Max 400 (300 GB/s on the cut-down bin — we use 400);
    /// M4 120 · M4 Pro 273 · M4 Max 546.
    /// Order matters: check the most specific suffix (Ultra/Max/Pro) before the base chip.
    package static func bandwidth(forBrandString brand: String) -> Double {
        let s = brand.lowercased()
        // Helper: does the brand mention this generation token ("m1".."m4")?
        func gen(_ token: String) -> Bool { s.contains(token) }

        if s.contains("ultra") {
            if gen("m1") { return 800 }
            if gen("m2") { return 800 }
            return 800 // future Ultra parts: assume flagship-class
        }
        if s.contains("max") {
            if gen("m1") { return 400 }
            if gen("m2") { return 400 }
            if gen("m3") { return 400 }
            if gen("m4") { return 546 }
            return 400
        }
        if s.contains("pro") {
            if gen("m1") { return 200 }
            if gen("m2") { return 200 }
            if gen("m3") { return 150 }
            if gen("m4") { return 273 }
            return 200
        }
        // Base chips (no Pro/Max/Ultra suffix).
        if gen("m1") { return 68 }
        if gen("m2") { return 100 }
        if gen("m3") { return 100 }
        if gen("m4") { return 120 }
        // Apple Silicon we don't recognise, or an Intel Mac brand string.
        return fallbackBandwidthGBs
    }

    // MARK: Machine-identifier mapping (iOS / visionOS)

    /// Maps an iOS `hw.machine` identifier (e.g. "iPhone16,1") to a conservative GB/s.
    ///
    /// iOS restricts `machdep.cpu.brand_string`, so we approximate from the device
    /// generation. A-series phone/tablet bandwidth is far lower than desktop M-series:
    /// A14/A15 ~34 GB/s, A16 ~? (~50 GB/s estimated), A17 Pro ~? (~60 GB/s estimated),
    /// M-class iPads track their Mac counterparts. These are conservative estimates;
    /// Apple does not publish A-series bandwidth, so we err low.
    package static func bandwidth(forIOSMachine machine: String) -> Double {
        // iPad with an M-series chip ("iPad14,x" Pro lines) — approximate as base M-class.
        // We cannot tell the exact M generation from the model string reliably, so use
        // a single conservative M-class figure rather than over-claiming.
        if machine.hasPrefix("iPad13") || machine.hasPrefix("iPad14")
            || machine.hasPrefix("iPad15") || machine.hasPrefix("iPad16") {
            return 100 // M-class iPad, conservative base-M figure
        }
        // Recent A-series phones. iPhone16,x = A17 Pro / A18 era.
        if machine.hasPrefix("iPhone16") || machine.hasPrefix("iPhone17") {
            return 60
        }
        if machine.hasPrefix("iPhone15") || machine.hasPrefix("iPhone14") {
            return 50
        }
        // Older / unrecognised iOS hardware: low estimate.
        return 34
    }

    // MARK: sysctl helpers

    #if os(macOS)
    /// Reads `machdep.cpu.brand_string` (e.g. "Apple M1 Pro"). Available on macOS;
    /// restricted on iOS, hence the platform guard.
    static func cpuBrandString() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let brand = String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
        return brand.isEmpty ? nil : brand
    }
    #endif

    #if os(iOS) || os(visionOS)
    /// Reads the `hw.machine` device identifier (e.g. "iPhone16,1").
    static func machineIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        let id = String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
        return id.isEmpty ? nil : id
    }
    #endif
}

// MARK: - Quantization → bits-per-weight

/// Maps a GGUF quantization tag to an approximate bits-per-weight, used for the
/// quality dimension. Lower bit-width trades capability for size; the scorer treats
/// a wider quant as higher quality at equal parameter count.
package enum QuantizationBits {

    /// Neutral default when the quant tag is missing or unrecognised (e.g. MLX
    /// snapshots that don't encode quant in the filename). 5.0 bpw sits between the
    /// common Q4 and Q6 levels so an unknown quant is neither rewarded nor punished.
    package static let neutralBitsPerWeight: Double = 5.0

    /// Approximate effective bits-per-weight for a GGUF quant tag like "Q4_K_M".
    /// Figures are the well-known llama.cpp ggml type sizes (effective bpw including
    /// block overhead), rounded to one decimal.
    package static func bitsPerWeight(for tag: String?) -> Double {
        guard let tag = tag?.uppercased() else { return neutralBitsPerWeight }

        // Full-precision floats first.
        if tag.hasPrefix("F32") { return 32.0 }
        if tag.hasPrefix("BF16") || tag.hasPrefix("F16") { return 16.0 }

        // K-quants and legacy quants, by leading digit. Match longer/more specific
        // tags before shorter ones where ambiguous.
        switch true {
        case tag.hasPrefix("Q8"):  return 8.5
        case tag.hasPrefix("Q6"):  return 6.6
        case tag.hasPrefix("Q5"):  return 5.5
        case tag.hasPrefix("Q4"):  return 4.5
        case tag.hasPrefix("IQ4"): return 4.25
        case tag.hasPrefix("Q3"):  return 3.4
        case tag.hasPrefix("IQ3"): return 3.1
        case tag.hasPrefix("Q2"):  return 2.6
        case tag.hasPrefix("IQ2"): return 2.2
        case tag.hasPrefix("IQ1"): return 1.6
        default:                   return neutralBitsPerWeight
        }
    }
}

// MARK: - Model Fit Scorer

/// Scores and ranks downloadable models by a composite of four dimensions —
/// quality, speed, fit, context — under a use-case-specific weighting.
///
/// ## Dimensions
/// - **quality**: capability proxy from `ModelCapabilityTier` (size tier) scaled by
///   quantization bits-per-weight. Larger + wider-quant ⇒ higher.
/// - **speed**: `bandwidthGBs / modelSizeGB × efficiencyFactor`, normalised. Decode
///   throughput is memory-bandwidth bound, so this approximates tokens/sec.
/// - **fit**: derived from `ModelLoadPlan.estimate(...)` — `.allow` ⇒ high, `.warn` ⇒
///   mid, `.deny` ⇒ 0. We reuse the load plan rather than recomputing memory math.
/// - **context**: known context length vs. the use case's `contextNeed`. Neutral
///   (0.5) when the context length is unknown (the common pre-download case).
///
/// The scorer is a pure value type: no I/O, no mutation, fully `Sendable`.
public struct ModelFitScorer: Sendable {

    /// Reference decode throughput (tokens/sec) at which `speed` saturates to 1.0.
    /// Tuned so that a flagship M-class device on a small model approaches the cap
    /// while a phone on a 7B model lands mid-range. Ranking is relative, so the exact
    /// value only sets the normalisation curve, not the ordering.
    private let speedSaturationTokensPerSecond: Double

    /// Fudge factor translating "GB/s per GB of weights" into a tokens/sec estimate.
    /// Real throughput is lower than the raw bandwidth/size ratio due to compute,
    /// sampling, and memory-subsystem inefficiency; 1 GB of weights streamed once per
    /// token at the device's bandwidth is the upper bound.
    private let efficiencyFactor: Double

    public init(
        speedSaturationTokensPerSecond: Double = 120.0,
        efficiencyFactor: Double = 1.0
    ) {
        self.speedSaturationTokensPerSecond = speedSaturationTokensPerSecond
        self.efficiencyFactor = efficiencyFactor
    }

    /// Scores a single model under a use case.
    ///
    /// - Parameters:
    ///   - model: The downloadable candidate.
    ///   - useCase: Biases the dimension weights and context need.
    ///   - requestedContextSize: Context size to evaluate the fit dimension at.
    ///   - knownContextLength: The model's trained context length when known (e.g.
    ///     from `CuratedModel.contextSize`). `nil` for arbitrary HF search results,
    ///     where pre-download context length is genuinely unknown — the context
    ///     dimension is then neutral. We never fabricate a context length.
    ///   - device: Device profile supplying memory + bandwidth (injectable for tests).
    ///   - environment: Memory environment for the `ModelLoadPlan` fit estimate.
    /// - Returns: A `ModelFitScore`, or `nil` if the model has no usable size (size 0).
    public func score(
        _ model: DownloadableModel,
        useCase: ModelUseCase,
        requestedContextSize: Int = 4_096,
        knownContextLength: Int? = nil,
        device: DeviceProfile = .current,
        environment: ModelLoadPlan.Environment? = nil
    ) -> ModelFitScore? {
        guard model.sizeBytes > 0 else { return nil }

        let weights = useCase.weights

        // --- fit: reuse ModelLoadPlan; do NOT recompute resident/KV byte math. ---
        let env = environment ?? ModelLoadPlan.Environment(
            availableMemoryBytes: { device.usableMemoryBytes },
            physicalMemoryBytes: device.physicalMemoryBytes
        )
        let plan = ModelLoadPlan.estimate(
            for: model,
            requestedContextSize: requestedContextSize,
            environment: env
        )
        let willRun = plan.verdict != .deny
        let fit: Double
        switch plan.verdict {
        case .allow: fit = 1.0
        case .warn:  fit = 0.5
        case .deny:  fit = 0.0
        }

        // --- quality: size tier × quantization width. ---
        let quality = qualityScore(for: model)

        // --- speed: bandwidth ÷ footprint, scaled, normalised against saturation. ---
        let modelSizeGB = max(Double(model.sizeBytes) / 1_073_741_824, 0.001)
        let estimatedTPS = (device.memoryBandwidthGBs / modelSizeGB) * efficiencyFactor
        let speed = clamp01(estimatedTPS / speedSaturationTokensPerSecond)

        // --- context: known length vs. need; neutral when unknown. ---
        let context: Double
        if let known = knownContextLength, known > 0 {
            context = clamp01(Double(known) / Double(max(useCase.contextNeed, 1)))
        } else {
            // Pre-download context length is unknown for arbitrary HF models; stay
            // neutral rather than fabricating a value. See ModelUseCase.contextNeed.
            context = 0.5
        }

        let weightedSum = quality * weights.quality
            + speed * weights.speed
            + fit * weights.fit
            + context * weights.context

        // A model that won't load is useless regardless of how capable it is, so a
        // `.deny` verdict must rank below every runnable candidate — not merely lose
        // the fit dimension's weight. Without this gate a 30B frontier model that
        // can't fit would still out-score a 7B that runs, because its quality term
        // dominates. Collapse the composite into a strictly-lower band when the load
        // plan denies. (`.warn` keeps its proportional fit penalty — it can still run.)
        let composite = willRun ? weightedSum : weightedSum * 0.1

        return ModelFitScore(
            quality: quality,
            speed: speed,
            fit: fit,
            context: context,
            composite: composite,
            estimatedTokensPerSecond: estimatedTPS,
            memoryBytes: plan.outcome.totalEstimatedBytes,
            willRun: willRun
        )
    }

    /// Ranks models best-first (descending composite) under a use case.
    ///
    /// Models that fail to score (size 0) are dropped. `knownContextLength` cannot be
    /// supplied per-model here because `DownloadableModel` does not carry it; callers
    /// with curated context data should call `score(...)` directly per variant.
    public func rank(
        _ models: [DownloadableModel],
        useCase: ModelUseCase,
        requestedContextSize: Int = 4_096,
        device: DeviceProfile = .current,
        environment: ModelLoadPlan.Environment? = nil
    ) -> [(DownloadableModel, ModelFitScore)] {
        models.compactMap { model in
            guard let s = score(
                model,
                useCase: useCase,
                requestedContextSize: requestedContextSize,
                device: device,
                environment: environment
            ) else { return nil }
            return (model, s)
        }
        .sorted { $0.1.composite > $1.1.composite }
    }

    // MARK: - Quality

    /// Capability proxy in 0...1 from size tier and quantization width.
    ///
    /// Param count (proxied by file size via `ModelCapabilityTier`) is the dominant
    /// term; quantization width modulates within a tier. We deliberately read the
    /// tier from `DownloadableModel.sizeBytes` rather than adding fields to
    /// `ModelCapabilityTier`, which is a pure file-size enum by design.
    private func qualityScore(for model: DownloadableModel) -> Double {
        // Reconstruct the tier from size using the same thresholds ModelCapabilityTier
        // applies to on-disk models, then map to a 0...1 capability base.
        let gb = Double(model.sizeBytes) / 1_073_741_824
        let tierBase: Double
        switch gb {
        case ..<2:    tierBase = 0.20  // minimal
        case 2..<5:   tierBase = 0.45  // fast
        case 5..<10:  tierBase = 0.65  // balanced
        case 10..<21: tierBase = 0.85  // capable
        default:      tierBase = 1.00  // frontier
        }

        // Quantization width modulates quality meaningfully. There is a well-known
        // perplexity cliff below ~Q3: 2-bit quants degrade so much that a wider-quant
        // model one size tier down is usually the better pick. We model this with an
        // accelerating-below-Q4 curve rather than a straight line: above ~4 bpw the
        // factor is gentle (0.90...1.0, diminishing returns past Q6), but below it the
        // penalty steepens so a Q2 (factor ~0.55) cannot ride its larger param count
        // past a Q4/Q5 of the adjacent smaller tier.
        let bpw = QuantizationBits.bitsPerWeight(for: model.quantization)
        let quantFactor: Double
        if bpw >= 4.0 {
            // 4 bpw → 0.90, 8.5 bpw → ~1.0.
            quantFactor = clamp(0.90 + (bpw - 4.0) / 4.5 * 0.10, min: 0.90, max: 1.0)
        } else {
            // 4 bpw → 0.90 down to ~2 bpw → 0.50: steep penalty in the sub-Q4 cliff.
            quantFactor = clamp(0.50 + (bpw - 2.0) / 2.0 * 0.40, min: 0.40, max: 0.90)
        }

        return clamp01(tierBase * quantFactor)
    }

    // MARK: - Math helpers

    private func clamp01(_ x: Double) -> Double { clamp(x, min: 0.0, max: 1.0) }
    private func clamp(_ x: Double, min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, x))
    }
}
