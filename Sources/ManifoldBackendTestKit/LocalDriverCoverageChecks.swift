import XCTest
import Foundation
import ManifoldInference

/// Real-driver coverage and adapter-shape checks for `LocalInferenceAdapter`
/// implementations (Phase 2.5 guard, parameterized for companion packages).
///
/// Why it exists: the local-backend contract suite may be satisfied with
/// `MockInferenceBackend`-scripted fixtures. Without this gate, a refactor
/// could "satisfy" a capability claim with a mock-only fixture while quietly
/// deleting the real-driver path that previously implemented it. The coverage
/// check reads the **production driver source** and verifies a sentinel token
/// for each claimed capability is still present.
///
/// The sentinels are intentionally coarse (substring match against the
/// production source) — they're a tripwire, not a coverage measure. The goal
/// is "if this capability gets deleted from the driver, this test fails
/// fast." Pair with the local-backend contract suite for behavioural proof.
public enum LocalDriverCoverageChecks {

    // MARK: - Capability → driver-source sentinel map

    /// Substring tokens that must appear in the named driver's source file
    /// for each claimed capability. Choosing distinct tokens per capability
    /// avoids false-greens when one keyword carries multiple meanings.
    public struct CapabilitySentinel: Sendable {
        public let label: String
        /// Closure that returns `true` when the claim is set on the
        /// capability struct. We pass the BackendCapabilities through so a
        /// future capability gets type-checked, not stringly-coded.
        public let claimed: @Sendable (BackendCapabilities) -> Bool
        /// Substring that must appear in the production source.
        public let sourceToken: String

        public init(
            label: String,
            claimed: @escaping @Sendable (BackendCapabilities) -> Bool,
            sourceToken: String
        ) {
            self.label = label
            self.claimed = claimed
            self.sourceToken = sourceToken
        }
    }

    /// Default sentinel set shared by the shipping local drivers.
    public static let defaultSentinels: [CapabilitySentinel] = [
        CapabilitySentinel(
            label: "supportsStreaming",
            claimed: { $0.supportsStreaming },
            sourceToken: "continuation.yield"
        ),
        CapabilitySentinel(
            label: "supportsToolCalling",
            claimed: { $0.supportsToolCalling },
            sourceToken: "ToolCallTransform"
        ),
        CapabilitySentinel(
            label: "supportsThinking",
            claimed: { $0.supportsThinking },
            sourceToken: "ThinkingTransform"
        ),
        CapabilitySentinel(
            label: "cancellationStyle == .cooperative",
            claimed: { $0.cancellationStyle == .cooperative },
            sourceToken: "isCancelled"
        ),
    ]

    // MARK: - Coverage assertion

    /// Asserts that every capability `adapter` claims has a sentinel token
    /// present in its production driver source, located by walking up from
    /// the calling test's `#filePath` until `sourceFileSuffix` resolves.
    public static func assertCoverage(
        adapter: any LocalInferenceAdapter,
        sourceFileSuffix: String,
        sentinels: [CapabilitySentinel] = defaultSentinels,
        filePath: StaticString = #filePath,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let caps = adapter.declaredCapabilities
        let sourceURL = try locateRepoFile(suffix: sourceFileSuffix, filePath: filePath)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        var missing: [String] = []
        for sentinel in sentinels where sentinel.claimed(caps) {
            if !source.contains(sentinel.sourceToken) {
                missing.append("\(sentinel.label) → token '\(sentinel.sourceToken)' not found")
            }
        }

        XCTAssertTrue(missing.isEmpty, """
            \(adapter.adapterName) claims capabilities its driver source does not implement:
              \(missing.joined(separator: "\n  "))

            Fix one of:
              1. The capability is no longer supported — drop it from declaredCapabilities.
              2. The implementation moved — update the sentinel token / sentinel list.
              3. A refactor accidentally deleted the real-driver path — restore it.
            """, file: file, line: line)
    }

    // MARK: - Adapter-shape smoke assertion

    /// Smoke conformance assertion for `LocalInferenceAdapter`: name, tool-call
    /// shape witness, thinking-marker strategy, and internal coherence of the
    /// declared capabilities. Structural counterpart to the behavioural
    /// contract suite — catches a driver landing without its conformance
    /// metadata aligned with the backend's claimed capabilities.
    public static func assertAdapterShape(
        _ adapter: any LocalInferenceAdapter,
        expectedName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(adapter.adapterName, expectedName, file: file, line: line)
        XCTAssertEqual(adapter.toolCallShape.shapeName, "local.inline-xml", file: file, line: line)
        XCTAssertEqual(adapter.thinkingMarkerStrategy, .eagerWhenMarkersPresent, file: file, line: line)

        let caps = adapter.declaredCapabilities
        XCTAssertFalse(caps.isRemote, "Local adapter cannot claim isRemote=true",
                       file: file, line: line)
        XCTAssertEqual(caps.cancellationStyle, .cooperative,
                       "Both shipping local drivers use cooperative cancellation",
                       file: file, line: line)
        XCTAssertTrue(caps.supportsStreaming, "Local drivers always stream",
                      file: file, line: line)
        XCTAssertTrue(caps.supportsThinking,
                      "Driver advertises thinking via thinkingMarkerStrategy = .eagerWhenMarkersPresent",
                      file: file, line: line)
    }

    // MARK: - Source location

    /// Walks up from `filePath` until `suffix` resolves to an existing file.
    public static func locateRepoFile(
        suffix: String,
        filePath: StaticString = #filePath
    ) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "LocalDriverCoverageChecks",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(suffix) walking up from \(filePath)"]
        )
    }
}
