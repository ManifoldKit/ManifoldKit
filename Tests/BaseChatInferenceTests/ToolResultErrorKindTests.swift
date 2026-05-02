import XCTest
@testable import BaseChatInference

/// Tests for the ``ToolResult/ErrorKind`` taxonomy and the backwards-compat
/// Codable path that accepts the legacy `isError` boolean.
final class ToolResultErrorKindTests: XCTestCase {

    // MARK: - ErrorKind round-trips

    func test_allErrorKinds_roundTripThroughCodable() throws {
        let allKinds: [ToolResult.ErrorKind] = [
            .invalidArguments, .permissionDenied, .notFound, .timeout,
            .rateLimited, .cancelled, .transient, .permanent, .unknownTool
        ]
        // Guard against someone adding a new case and forgetting to update the
        // test exhaustively. 9 cases is the wave 1 contract.
        XCTAssertEqual(allKinds.count, 9)

        for kind in allKinds {
            let result = ToolResult(callId: "c-\(kind.rawValue)", content: "x", errorKind: kind)
            let encoded = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)
            XCTAssertEqual(decoded.errorKind, kind, "round-trip failed for \(kind.rawValue)")
            XCTAssertTrue(decoded.isError)
        }
    }

    func test_allErrorKinds_haveLocalizedUserFacingDescriptions() {
        let expected: [ToolResult.ErrorKind: String] = [
            .invalidArguments: "The tool couldn't understand those details.",
            .permissionDenied: "Permission is required to use this tool.",
            .notFound: "The requested item couldn't be found.",
            .timeout: "The tool took too long to respond.",
            .rateLimited: "The tool is temporarily rate limited.",
            .cancelled: "The tool call was cancelled.",
            .transient: "The tool hit a temporary problem.",
            .permanent: "The tool couldn't complete this request.",
            .unknownTool: "This tool isn't available.",
        ]

        XCTAssertEqual(ToolResult.ErrorKind.allCases.count, 9)
        for kind in ToolResult.ErrorKind.allCases {
            XCTAssertEqual(kind.localizedDescription, expected[kind], "missing localized description for \(kind.rawValue)")
            XCTAssertNotEqual(kind.localizedDescription, kind.rawValue)
        }
    }

    func test_successResult_encodesWithoutErrorKind() throws {
        let result = ToolResult(callId: "c", content: "ok")
        let encoded = try JSONEncoder().encode(result)
        // Ensure `isError` is not emitted on the wire — it is purely derived.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(obj["errorKind"])
        XCTAssertNil(obj["isError"], "isError must not be encoded — it is derived from errorKind")
    }

    // MARK: - Backwards-compat decode

    func test_backwardsCompatDecode_isErrorTrue_mapsToPermanent() throws {
        let legacy = #"{"callId":"x","content":"y","isError":true}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: legacy)

        // Sabotage check: removing the isError fallback branch in init(from:)
        // makes this fail because errorKind will be nil.
        XCTAssertEqual(decoded.errorKind, .permanent)
        XCTAssertTrue(decoded.isError)
        XCTAssertEqual(decoded.callId, "x")
        XCTAssertEqual(decoded.content, "y")
    }

    func test_backwardsCompatDecode_isErrorFalse_mapsToNil() throws {
        let legacy = #"{"callId":"x","content":"y","isError":false}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: legacy)

        XCTAssertNil(decoded.errorKind)
        XCTAssertFalse(decoded.isError)
    }

    func test_decode_withNeitherField_defaultsToNil() throws {
        let minimal = #"{"callId":"x","content":"y"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: minimal)

        XCTAssertNil(decoded.errorKind)
        XCTAssertFalse(decoded.isError)
    }

    func test_forwardCompatDecode_errorKindWinsOverLegacyIsError() throws {
        // Both fields present — errorKind must take precedence so new servers
        // sending both shapes do not silently downgrade to `.permanent`.
        let mixed = #"{"callId":"x","content":"y","errorKind":"timeout","isError":true}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: mixed)

        XCTAssertEqual(decoded.errorKind, .timeout)
        XCTAssertTrue(decoded.isError)
    }

    // MARK: - Deprecated initializer

    func test_deprecatedInit_isErrorTrue_mapsToPermanent() {
        // Intentionally exercise the deprecated initializer. `@available`
        // deprecation warnings are expected; the initializer is retained for
        // migration compatibility.
        @available(*, deprecated)
        func makeLegacy() -> ToolResult {
            ToolResult(callId: "c", content: "x", isError: true)
        }

        let result = makeLegacy()
        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertTrue(result.isError)
    }

    func test_deprecatedInit_isErrorFalse_mapsToNil() {
        @available(*, deprecated)
        func makeLegacy() -> ToolResult {
            ToolResult(callId: "c", content: "x", isError: false)
        }

        let result = makeLegacy()
        XCTAssertNil(result.errorKind)
        XCTAssertFalse(result.isError)
    }

    // MARK: - Equatable / Hashable

    func test_resultsWithDifferentErrorKinds_areNotEqual() {
        let a = ToolResult(callId: "c", content: "x", errorKind: .timeout)
        let b = ToolResult(callId: "c", content: "x", errorKind: .permanent)
        XCTAssertNotEqual(a, b)
    }
}
