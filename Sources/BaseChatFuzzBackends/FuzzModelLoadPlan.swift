import BaseChatInference

extension ModelLoadPlan {
    static func fuzzStub(effectiveContextSize: Int) -> ModelLoadPlan {
        let inputs = Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: effectiveContextSize,
            trainedContextLength: nil,
            kvBytesPerToken: 0,
            availableMemoryBytes: UInt64.max,
            physicalMemoryBytes: UInt64.max,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        )
        let outcome = Outcome(
            effectiveContextSize: max(1, effectiveContextSize),
            estimatedResidentBytes: 0,
            estimatedKVBytes: 0,
            totalEstimatedBytes: 0,
            verdict: .allow,
            reasons: []
        )
        return ModelLoadPlan(inputs: inputs, outcome: outcome)
    }
}
