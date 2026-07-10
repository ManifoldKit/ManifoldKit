import XCTest
@testable import ManifoldHardware

/// Covers the Wave 2 A1 stable-code migration: raw values are opaque codes,
/// `displayName` carries the old human labels, and `parse(_:)` accepts both the
/// new codes and the legacy pre-0.68 display strings.
final class APIProviderTests: XCTestCase {

    func test_rawValues_areStableCodes() {
        XCTAssertEqual(APIProvider.openAI.rawValue, "openAI")
        XCTAssertEqual(APIProvider.openAIResponses.rawValue, "openAIResponses")
        XCTAssertEqual(APIProvider.claude.rawValue, "claude")
        XCTAssertEqual(APIProvider.ollama.rawValue, "ollama")
        XCTAssertEqual(APIProvider.lmStudio.rawValue, "lmStudio")
        XCTAssertEqual(APIProvider.custom.rawValue, "custom")
    }

    func test_displayName_carriesHumanLabels() {
        XCTAssertEqual(APIProvider.openAI.displayName, "OpenAI")
        XCTAssertEqual(APIProvider.openAIResponses.displayName, "OpenAI Responses")
        XCTAssertEqual(APIProvider.claude.displayName, "Claude")
        XCTAssertEqual(APIProvider.ollama.displayName, "Ollama")
        XCTAssertEqual(APIProvider.lmStudio.displayName, "LM Studio")
        XCTAssertEqual(APIProvider.custom.displayName, "Custom")
    }

    // MARK: - parse() table

    func test_parse_acceptsNewStableCodes() {
        let table: [(String, APIProvider)] = [
            ("openAI", .openAI),
            ("openAIResponses", .openAIResponses),
            ("claude", .claude),
            ("ollama", .ollama),
            ("lmStudio", .lmStudio),
            ("custom", .custom),
        ]
        for (raw, expected) in table {
            XCTAssertEqual(APIProvider.parse(raw), expected,
                           "Stable code \"\(raw)\" should parse to \(expected)")
        }
    }

    func test_parse_acceptsLegacyDisplayStrings() {
        let table: [(String, APIProvider)] = [
            ("OpenAI", .openAI),
            ("OpenAI Responses", .openAIResponses),
            ("Claude", .claude),
            ("Ollama", .ollama),
            ("LM Studio", .lmStudio),
            ("Custom", .custom),
        ]
        for (raw, expected) in table {
            XCTAssertEqual(APIProvider.parse(raw), expected,
                           "Legacy display string \"\(raw)\" should migrate to \(expected)")
        }
    }

    func test_parse_returnsNilForUnknown() {
        XCTAssertNil(APIProvider.parse("NotAProvider"))
        XCTAssertNil(APIProvider.parse(""))
        XCTAssertNil(APIProvider.parse("gemini"))
    }

    // MARK: - Codable

    func test_codable_roundTripEmitsStableCode() throws {
        for provider in APIProvider.allCases {
            let data = try JSONEncoder().encode(provider)
            let decodedString = try JSONDecoder().decode(String.self, from: data)
            XCTAssertEqual(decodedString, provider.rawValue,
                           "Encoding must emit the stable code")
            let decoded = try JSONDecoder().decode(APIProvider.self, from: data)
            XCTAssertEqual(decoded, provider)
        }
    }

    func test_codable_decodesLegacyDisplayString() throws {
        let data = Data("\"LM Studio\"".utf8)
        let decoded = try JSONDecoder().decode(APIProvider.self, from: data)
        XCTAssertEqual(decoded, .lmStudio)
    }

    func test_codable_throwsOnUnknownString() {
        let data = Data("\"NotAProvider\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(APIProvider.self, from: data))
    }
}
