import XCTest
import ManifoldInference
#if Llama
@testable import ManifoldLlama
#endif
#if MLX
@testable import ManifoldMLX
#endif

/// Phase 2.5 guard: every local backend has at least one real-driver code
/// path for each capability it claims in `BackendCapabilities`.
///
/// Why it exists: Phase 4 of the cross-backend unification plan promotes
/// `InferenceBackendContractTests` to local backends with fixtures that may
/// be `MockInferenceBackend`-scripted. Without this gate, a refactor could
/// "satisfy" a capability claim with a mock-only fixture while quietly
/// deleting the real-driver path that previously implemented it. This
/// test reads the **production driver source** and verifies a sentinel
/// token for each claimed capability is still present.
///
/// The sentinels are intentionally coarse (substring match against the
/// production source) — they're a tripwire, not a coverage measure. The
/// goal is "if this capability gets deleted from the driver, this test
/// fails fast." Pair with `InferenceBackendContractTests` for behavioural
/// proof.
final class LocalBackendRealDriverCoverageTest: XCTestCase {

    // MARK: - Capability → driver-source sentinel map

    /// Substring tokens that must appear in the named driver's source file
    /// for each claimed capability. Choosing distinct tokens per capability
    /// avoids false-greens when one keyword carries multiple meanings.
    private struct CapabilitySentinel: Sendable {
        let label: String
        /// Closure that returns `true` when the claim is set on the
        /// capability struct. We pass the BackendCapabilities through so a
        /// future capability gets type-checked, not stringly-coded.
        let claimed: @Sendable (BackendCapabilities) -> Bool
        /// Substring that must appear in the production source.
        let sourceToken: String
    }

    private static let sentinels: [CapabilitySentinel] = [
        CapabilitySentinel(
            label: "supportsStreaming",
            claimed: { $0.supportsStreaming },
            sourceToken: "continuation.yield"
        ),
        CapabilitySentinel(
            label: "supportsToolCalling",
            claimed: { $0.supportsToolCalling },
            sourceToken: "ToolCallParser"
        ),
        CapabilitySentinel(
            label: "supportsThinking",
            claimed: { $0.supportsThinking },
            sourceToken: "ThinkingParser"
        ),
        CapabilitySentinel(
            label: "cancellationStyle == .cooperative",
            claimed: { $0.cancellationStyle == .cooperative },
            sourceToken: "isCancelled"
        ),
    ]

    // MARK: - Llama

    #if Llama
    func test_llamaDriverHasRealPathForEveryClaim() throws {
        let driver = LlamaGenerationDriver()
        try assertCoverage(
            adapter: driver,
            sourceFileSuffix: "Sources/ManifoldLlama/LlamaGenerationDriver.swift"
        )
    }
    #endif

    // MARK: - MLX

    #if MLX
    @MainActor
    func test_mlxDriverHasRealPathForEveryClaim() throws {
        let driver = MLXGenerationDriver()
        try assertCoverage(
            adapter: driver,
            sourceFileSuffix: "Sources/ManifoldMLX/MLX/MLXGenerationDriver.swift"
        )
    }
    #endif

    // MARK: - Helper

    private func assertCoverage(
        adapter: any LocalInferenceAdapter,
        sourceFileSuffix: String,
        filePath: StaticString = #filePath
    ) throws {
        let caps = adapter.declaredCapabilities
        let sourceURL = try Self.locateRepoFile(suffix: sourceFileSuffix, filePath: filePath)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        var missing: [String] = []
        for sentinel in Self.sentinels where sentinel.claimed(caps) {
            if !source.contains(sentinel.sourceToken) {
                missing.append("\(sentinel.label) → token '\(sentinel.sourceToken)' not found")
            }
        }

        XCTAssertTrue(missing.isEmpty, """
            \(adapter.adapterName) claims capabilities its driver source does not implement:
              \(missing.joined(separator: "\n  "))

            Fix one of:
              1. The capability is no longer supported — drop it from declaredCapabilities.
              2. The implementation moved — update the sentinel token in this test.
              3. A refactor accidentally deleted the real-driver path — restore it.
            """)
    }

    private static func locateRepoFile(suffix: String, filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "LocalBackendRealDriverCoverageTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(suffix) walking up from \(filePath)"]
        )
    }
}
