#if Fuzz
import Foundation
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that produces a fresh `MockInferenceBackend`
/// per iteration. Used by the PR-tier CI fuzz job where no model or network is
/// available — the mock backend is deterministic, hardware-free, and exercises
/// the detectors, sink, and corpus wiring without touching a real model.
///
/// The factory intentionally pre-loads the backend via `loadModel(from:plan:)`
/// so `FuzzRunner`'s `runSingle` does not hit the `"No model loaded"` error
/// path on every iteration — the harness expects a ready-to-generate handle.
public struct MockFuzzFactory: FuzzBackendFactory {
    public let tokensToYield: [String]
    public let thinkingTokensToYield: [String]

    public init(
        tokensToYield: [String] = ["Hello", " ", "world", "."],
        thinkingTokensToYield: [String] = []
    ) {
        self.tokensToYield = tokensToYield
        self.thinkingTokensToYield = thinkingTokensToYield
    }

    @MainActor
    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let backend = MockInferenceBackend()
        backend.tokensToYield = tokensToYield
        backend.thinkingTokensToYield = thinkingTokensToYield
        try await backend.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())
        let markers = RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: "mock-model",
            modelURL: URL(string: "mock:mock-model")!,
            backendName: "mock",
            templateMarkers: markers
        )
    }
}
#endif
