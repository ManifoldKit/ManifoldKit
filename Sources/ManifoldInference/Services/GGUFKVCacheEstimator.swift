import Foundation

package struct GGUFKVCacheParameters: Sendable, Equatable {
    let blockCount: Int?
    let embeddingLength: Int?
    let attentionHeadCount: Int?
    let attentionHeadCountKV: Int?
    let attentionKeyLength: Int?
    let attentionValueLength: Int?

    package init(
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

package enum GGUFKVCacheEstimator {
    package static let defaultBytesPerElement: UInt64 = 2
    package static let legacyFallbackBytesPerToken: UInt64 = 8_192

    package static func estimateBytesPerToken(
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

        return UInt64(blockCount) * UInt64(keyWidth + valueWidth) * bytesPerElement
    }

    static func estimateBytesPerToken(
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
        if let explicitHeadLength = positive(explicitHeadLength) {
            return explicitHeadLength * kvHeadCount
        }

        guard let embeddingLength = positive(embeddingLength),
              let headCount = positive(headCount),
              embeddingLength % headCount == 0 else {
            return nil
        }

        return (embeddingLength / headCount) * kvHeadCount
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
