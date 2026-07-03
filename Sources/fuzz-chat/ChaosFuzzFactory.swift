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
    /// small.
    ///
    /// Grammar: colon-separated positional integer parameters after the mode
    /// name. An **empty** segment keeps that position's default — so
    /// `burst-then-stall::5000` means "default burstSize, 5000 ms stall"
    /// (splitting must NOT omit empty subsequences, or the 5000 would silently
    /// shift into the burstSize slot). Returns `nil` on an unrecognised name
    /// or a malformed numeric parameter; the caller is expected to `fail()`
    /// with ``usage``.
    public static func parseMode(_ spec: String) -> ChaosBackend.FailureMode? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // Positional parameter accessor: absent or empty segment → the mode's
        // documented default; a non-empty segment must parse as Int or the
        // whole spec is rejected (nil).
        func int(_ i: Int, default def: Int) -> Int? {
            guard parts.count > i, !parts[i].isEmpty else { return def }
            return Int(parts[i])
        }
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
                              Params are positional integers; leave a segment
                              empty to keep its default (burst-then-stall::5000
                              = default burstSize, 5000 ms stall).
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
