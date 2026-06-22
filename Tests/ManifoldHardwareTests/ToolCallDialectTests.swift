import XCTest
@testable import ManifoldHardware

final class ToolCallDialectTests: XCTestCase {
    func testDialectCodableRoundTrip() throws {
        let dialect = ToolCallDialect.gemma
        let data = try JSONEncoder().encode(dialect)
        let decoded = try JSONDecoder().decode(ToolCallDialect.self, from: data)
        XCTAssertEqual(decoded, dialect)
        XCTAssertEqual(decoded.family, .gemma)
        XCTAssertEqual(decoded.argEncoding, .keyValue)
    }

    func testCustomDialectWithNilDelimitersRoundTrips() throws {
        let dialect = ToolCallDialect(
            family: .llamaPythonTag,
            openDelimiter: nil,
            closeDelimiter: nil,
            argEncoding: .json,
            extractability: .buried
        )
        let data = try JSONEncoder().encode(dialect)
        let decoded = try JSONDecoder().decode(ToolCallDialect.self, from: data)
        XCTAssertEqual(decoded, dialect)
        XCTAssertNil(decoded.openDelimiter)
        XCTAssertNil(decoded.closeDelimiter)
    }

    func testCapabilitiesWithToolDialectRoundTrips() throws {
        let caps = BackendCapabilities(
            supportsToolCalling: true,
            toolDialect: .qwen
        )
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: data)
        XCTAssertEqual(decoded.toolDialect, .qwen)
        XCTAssertEqual(decoded.toolDialect?.openDelimiter, "<tool_call>")
    }

    func testCapabilitiesDialectDefaultsNilAndDecodesTolerantly() throws {
        // A blob with no toolDialect key decodes to nil (additive/tolerant).
        let caps = BackendCapabilities(supportsToolCalling: false)
        XCTAssertNil(caps.toolDialect)
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: data)
        XCTAssertNil(decoded.toolDialect)
    }

    func testUnionCarriesFirstNonNilDialect() {
        let withoutDialect = BackendCapabilities(supportsToolCalling: false)
        let withDialect = BackendCapabilities(supportsToolCalling: true, toolDialect: .mistral)
        let unioned = BackendCapabilities.union([withoutDialect, withDialect])
        XCTAssertEqual(unioned.toolDialect, .mistral)
        XCTAssertTrue(unioned.supportsToolCalling)
    }

    func testUnionPrefersFirstDialectWhenMultiplePresent() {
        let a = BackendCapabilities(toolDialect: .hermes)
        let b = BackendCapabilities(toolDialect: .gemma)
        let unioned = BackendCapabilities.union([a, b])
        XCTAssertEqual(unioned.toolDialect, .hermes)
    }
}
