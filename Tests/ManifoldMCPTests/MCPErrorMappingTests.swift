import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

final class MCPErrorMappingTests: XCTestCase {

    // MARK: - Direct case → ErrorKind mappings

    func test_toolNotFound_mapsTo_unknownTool() {
        XCTAssertEqual(errorKind(for: .toolNotFound("search")), .unknownTool)
    }

    func test_requestTimeout_mapsTo_timeout() {
        XCTAssertEqual(errorKind(for: .requestTimeout), .timeout)
    }

    func test_cancelled_mapsTo_cancelled() {
        XCTAssertEqual(errorKind(for: .cancelled), .cancelled)
    }

    func test_authorizationRequired_mapsTo_permissionDenied() {
        let request = MCPAuthorizationRequest(serverID: UUID())
        XCTAssertEqual(errorKind(for: .authorizationRequired(request)), .permissionDenied)
    }

    func test_authorizationFailed_mapsTo_permissionDenied() {
        XCTAssertEqual(errorKind(for: .authorizationFailed("denied")), .permissionDenied)
    }

    func test_unauthorized_mapsTo_permissionDenied() {
        XCTAssertEqual(errorKind(for: .unauthorized), .permissionDenied)
    }

    func test_transportClosed_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .transportClosed), .transient)
    }

    func test_transportFailure_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .transportFailure("boom")), .transient)
    }

    func test_networkUnavailable_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .networkUnavailable), .transient)
    }

    func test_backgroundedDuringDispatch_mapsTo_transient() {
        XCTAssertEqual(errorKind(for: .backgroundedDuringDispatch), .transient)
    }

    // MARK: - Protocol error code switch

    func test_protocolError_methodNotFound_mapsTo_unknownTool() {
        let error = MCPError.protocolError(code: -32601, message: "method not found", data: nil)
        XCTAssertEqual(errorKind(for: error), .unknownTool)
    }

    func test_protocolError_invalidParams_mapsTo_invalidArguments() {
        let error = MCPError.protocolError(code: -32602, message: "invalid params", data: nil)
        XCTAssertEqual(errorKind(for: error), .invalidArguments)
    }

    func test_protocolError_internalError_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32603, message: "internal error", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_parseError_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32700, message: "parse error", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_invalidRequest_mapsTo_permanent() {
        let error = MCPError.protocolError(code: -32600, message: "invalid request", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_protocolError_serverDefinedCode_mapsTo_permanent() {
        let error = MCPError.protocolError(code: 1, message: "custom", data: nil)
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    // MARK: - Permanent fallthrough cases

    func test_unsupportedProtocolVersion_mapsTo_permanent() {
        let error = MCPError.unsupportedProtocolVersion(server: "2025-03-26", client: "2024-11-05")
        XCTAssertEqual(errorKind(for: error), .permanent)
    }

    func test_malformedMetadata_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .malformedMetadata("bad json")), .permanent)
    }

    func test_issuerMismatch_mapsTo_permanent() {
        let expected = URL(string: "https://expected.example.com")!
        let actual = URL(string: "https://actual.example.com")!
        XCTAssertEqual(errorKind(for: .issuerMismatch(expected: expected, actual: actual)), .permanent)
    }

    func test_dcrFailed_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .dcrFailed("registration rejected")), .permanent)
    }

    func test_ssrfBlocked_mapsTo_permanent() {
        let url = URL(string: "http://169.254.169.254/")!
        XCTAssertEqual(errorKind(for: .ssrfBlocked(url)), .permanent)
    }

    func test_tooManyTools_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .tooManyTools(500)), .permanent)
    }

    func test_oversizeContent_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .oversizeContent(1_000_000)), .permanent)
    }

    func test_oversizeMessage_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .oversizeMessage(1_000_000)), .permanent)
    }

    func test_failed_mapsTo_permanent() {
        XCTAssertEqual(errorKind(for: .failed("unspecified")), .permanent)
    }

    // MARK: - Coverage marker

    /// Forces a compile error if a new MCPError case is added without updating
    /// the mapping tests. Mirrors the exhaustive switch in MCPErrorMapping.swift.
    ///
    /// The switch has no `default:` clause, so adding a new ``MCPError`` case
    /// breaks compilation here until a corresponding `errorKind(for:)` call is
    /// added — the same compile-time pressure the production mapper relies on.
    func test_exhaustiveCaseCoverage_compileTimeMarker() {
        let error: MCPError = .transportClosed

        switch error {
        case .transportClosed:
            _ = errorKind(for: .transportClosed)
        case .transportFailure(let message):
            _ = errorKind(for: .transportFailure(message))
        case .protocolError(let code, let message, let data):
            _ = errorKind(for: .protocolError(code: code, message: message, data: data))
        case .requestTimeout:
            _ = errorKind(for: .requestTimeout)
        case .unsupportedProtocolVersion(let server, let client):
            _ = errorKind(for: .unsupportedProtocolVersion(server: server, client: client))
        case .authorizationRequired(let request):
            _ = errorKind(for: .authorizationRequired(request))
        case .authorizationFailed(let reason):
            _ = errorKind(for: .authorizationFailed(reason))
        case .dcrFailed(let reason):
            _ = errorKind(for: .dcrFailed(reason))
        case .malformedMetadata(let reason):
            _ = errorKind(for: .malformedMetadata(reason))
        case .issuerMismatch(let expected, let actual):
            _ = errorKind(for: .issuerMismatch(expected: expected, actual: actual))
        case .ssrfBlocked(let url):
            _ = errorKind(for: .ssrfBlocked(url))
        case .tooManyTools(let count):
            _ = errorKind(for: .tooManyTools(count))
        case .toolNotFound(let toolName):
            _ = errorKind(for: .toolNotFound(toolName))
        case .oversizeContent(let size):
            _ = errorKind(for: .oversizeContent(size))
        case .oversizeMessage(let size):
            _ = errorKind(for: .oversizeMessage(size))
        case .networkUnavailable:
            _ = errorKind(for: .networkUnavailable)
        case .unauthorized:
            _ = errorKind(for: .unauthorized)
        case .failed(let reason):
            _ = errorKind(for: .failed(reason))
        case .backgroundedDuringDispatch:
            _ = errorKind(for: .backgroundedDuringDispatch)
        case .cancelled:
            _ = errorKind(for: .cancelled)
        }
    }
}
