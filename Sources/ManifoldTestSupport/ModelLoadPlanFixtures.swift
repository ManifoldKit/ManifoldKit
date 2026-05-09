import ManifoldInference

extension ModelLoadPlan {
    /// Fixture for tests that just need a plan with a specific effective context size.
    /// Bypasses memory math entirely — the outcome is hard-coded to `.allow`.
    public static func testStub(effectiveContextSize: Int = 2048) -> ModelLoadPlan {
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
