import Foundation
import ManifoldFuzz
import ManifoldInference
import ManifoldTestSupport

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

    /// Parses the `--chaos-mode <name>[:params]` CLI spec into a
    /// ``ManifoldTestSupport/ChaosBackend/FailureMode``. Every mode is
    /// reachable from the CLI; modes with more than one or two parameters take
    /// fixed, documented defaults for the remainder to keep the flag syntax
    /// small. Returns `nil` on an unrecognised name or a malformed numeric
    /// parameter; the caller is expected to `fail()` with ``usage``.
    public static func parseMode(_ spec: String) -> ChaosBackend.FailureMode? {
        let parts = spec.split(separator: ":").map(String.init)
        func int(_ i: Int, default def: Int) -> Int? { parts.count > i ? Int(parts[i]) : def }
        switch parts.first {
        case "none": return .none
        case "drop-mid-stream":
            return int(1, default: 1).map { .dropMidStream(afterTokens: $0) }
        case "slow-first-token":
            return int(1, default: 1000).map { .slowFirstToken(delay: .milliseconds($0)) }
        case "burst-then-stall":
            guard let burst = int(1, default: 3), let stall = int(2, default: 2000) else { return nil }
            return .burstThenStall(burstSize: burst, stallDuration: .milliseconds(stall))
        case "network-error":
            return int(1, default: 1).map { .networkError(afterTokens: $0) }
        case "idle-timeout":
            guard let after = int(1, default: 1), let silence = int(2, default: 2000) else { return nil }
            return .idleTimeout(afterTokens: after, silenceFor: .milliseconds(silence))
        case "malformed-tool-call":
            return int(1, default: 1).map {
                .malformedToolCall(tokensBefore: $0, callId: "chaos-call", toolName: "chaos_tool", invalidJSON: "{not valid json")
            }
        case "parallel-tool-calls":
            return int(1, default: 2).map {
                .parallelToolCalls(count: $0, idPrefix: "chaos-call-", toolName: "chaos_tool")
            }
        default:
            return nil
        }
    }

    /// `--chaos-mode` usage text for `--help` and parse-error messages.
    public static let usage = """
        --chaos-mode <spec>  ChaosBackend failure mode (default: none). One of:
                              none | drop-mid-stream[:afterTokens] |
                              slow-first-token[:delayMs] |
                              burst-then-stall[:burstSize:stallMs] |
                              network-error[:afterTokens] |
                              idle-timeout[:afterTokens:silenceMs] |
                              malformed-tool-call[:tokensBefore] |
                              parallel-tool-calls[:count]
                              Only applies to --backend chaos.
        """

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
