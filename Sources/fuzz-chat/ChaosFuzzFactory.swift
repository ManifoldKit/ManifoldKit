#if Fuzz
import Foundation
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that produces a fresh `ChaosBackend` per
/// iteration with a fixed initial failure mode. Useful for exercising the
/// detector + sink plumbing against deliberate stream-drop / delay / error
/// injection without needing a real backend.
///
/// Defaults to `.none` (happy path with a short token list) so a PR-tier
/// campaign stays signal-light; tests and harnesses that want to exercise a
/// specific failure mode can pass one explicitly.
public struct ChaosFuzzFactory: FuzzBackendFactory {
    public let mode: ChaosBackend.FailureMode
    public let tokensToYield: [String]

    public init(
        mode: ChaosBackend.FailureMode = .none,
        tokensToYield: [String] = ["Hello", " ", "world", "."]
    ) {
        self.mode = mode
        self.tokensToYield = tokensToYield
    }

    @MainActor
    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let backend = ChaosBackend(mode: mode, tokensToYield: tokensToYield)
        try await backend.loadModel(from: URL(string: "chaos:chaos-model")!, plan: .cloud())
        let markers = RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: "chaos-model",
            modelURL: URL(string: "chaos:chaos-model")!,
            backendName: "chaos",
            templateMarkers: markers
        )
    }
}
#endif
