import Foundation

// @_spi(BackendInternals): published for the companion family packages
// (manifold-llama, #1749) — LlamaPrefillFootprintIntegrationTests derives its
// expected KV footprint from this estimator rather than an inlined constant.
// Part of the frozen backend seam (Tests/APIFreezeTests/Fixtures/
// BackendSeamConsumer.swift).
@_spi(BackendInternals)
public struct GGUFKVCacheParameters: Sendable, Equatable {
    let blockCount: Int?
    let embeddingLength: Int?
    let attentionHeadCount: Int?
    let attentionHeadCountKV: Int?
    let attentionKeyLength: Int?
    let attentionValueLength: Int?

    public init(
        blockCount: Int? = nil,
        embeddingLength: Int? = nil,
        attentionHeadCount: Int? = nil,
        attentionHeadCountKV: Int? = nil,
        attentionKeyLength: Int? = nil,
        attentionValueLength: Int? = nil
    ) {
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
        self.attentionHeadCount = attentionHeadCount
        self.attentionHeadCountKV = attentionHeadCountKV
        self.attentionKeyLength = attentionKeyLength
        self.attentionValueLength = attentionValueLength
    }
}

@_spi(BackendInternals)
public enum GGUFKVCacheEstimator {
    public static let defaultBytesPerElement: UInt64 = 2
    public static let legacyFallbackBytesPerToken: UInt64 = 8_192

    public static func estimateBytesPerToken(
        from parameters: GGUFKVCacheParameters,
        bytesPerElement: UInt64 = defaultBytesPerElement
    ) -> UInt64? {
        guard bytesPerElement > 0,
              let blockCount = positive(parameters.blockCount) else {
            return nil
        }

        let kvHeadCount = positive(parameters.attentionHeadCountKV)
            ?? positive(parameters.attentionHeadCount)

        guard let kvHeadCount else {
            return nil
        }

        guard let keyWidth = gqaWidth(
            explicitHeadLength: parameters.attentionKeyLength,
            embeddingLength: parameters.embeddingLength,
            headCount: parameters.attentionHeadCount,
            kvHeadCount: kvHeadCount
        ) else {
            return nil
        }

        guard let valueWidth = gqaWidth(
            explicitHeadLength: parameters.attentionValueLength ?? parameters.attentionKeyLength,
            embeddingLength: parameters.embeddingLength,
            headCount: parameters.attentionHeadCount,
            kvHeadCount: kvHeadCount
        ) else {
            return nil
        }

        // A malformed or crafted GGUF can supply enormous block/width values. An
        // unchecked UInt64 multiply would wrap to a tiny per-token estimate, so
        // ModelLoadPlan would report `.allow` and then OOM at inference. On any
        // overflow, return nil so the caller's conservative no-estimate fallback
        // (legacyFallbackBytesPerToken) engages instead. The Int sum below is
        // also overflow-checked: a trapping `+` would crash the process on a
        // crafted file rather than route to the fallback (gqaWidth itself is
        // overflow-hardened for the same reason).
        let (widthSum, sumOverflow) = keyWidth.addingReportingOverflow(valueWidth)
        guard !sumOverflow else { return nil }

        let (perTokenElements, widthOverflow) = UInt64(blockCount)
            .multipliedReportingOverflow(by: UInt64(widthSum))
        guard !widthOverflow else { return nil }

        let (bytesPerToken, byteOverflow) = perTokenElements
            .multipliedReportingOverflow(by: bytesPerElement)
        guard !byteOverflow else { return nil }

        return bytesPerToken
    }

    package static func estimateBytesPerToken(
        from metadata: GGUFMetadata,
        bytesPerElement: UInt64 = defaultBytesPerElement
    ) -> UInt64? {
        guard let parameters = metadata.kvCacheParameters else {
            return nil
        }
        return estimateBytesPerToken(from: parameters, bytesPerElement: bytesPerElement)
    }

    private static func gqaWidth(
        explicitHeadLength: Int?,
        embeddingLength: Int?,
        headCount: Int?,
        kvHeadCount: Int
    ) -> Int? {
        // Overflow-checked Int multiplies: a crafted GGUF can pair a huge head
        // length with a huge kvHeadCount; a trapping `*` would crash the process
        // instead of routing to the conservative fallback. Return nil on overflow.
        if let explicitHeadLength = positive(explicitHeadLength) {
            let (width, overflow) = explicitHeadLength.multipliedReportingOverflow(by: kvHeadCount)
            return overflow ? nil : width
        }

        guard let embeddingLength = positive(embeddingLength),
              let headCount = positive(headCount),
              embeddingLength % headCount == 0 else {
            return nil
        }

        let (width, overflow) = (embeddingLength / headCount).multipliedReportingOverflow(by: kvHeadCount)
        return overflow ? nil : width
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
