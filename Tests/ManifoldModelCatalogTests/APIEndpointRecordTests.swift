import XCTest
@testable import ManifoldModelCatalog
import ManifoldHardware

final class APIEndpointRecordTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_codableRoundTrip_preservesEveryField() throws {
        let original = APIEndpointRecord(
            id: UUID(),
            name: "My OpenAI",
            provider: .openAI,
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o-mini",
            keychainAccount: "keychain-account-123",
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            isEnabled: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(APIEndpointRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.baseURL, original.baseURL)
        XCTAssertEqual(decoded.modelName, original.modelName)
        XCTAssertEqual(decoded.keychainAccount, original.keychainAccount)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded, original, "Hashable/Equatable synthesis should agree with the field-by-field comparison above")
    }

    // MARK: - Wire-shape pin

    func test_codingKeys_matchPinnedWireContract() throws {
        // Pins the JSON key names themselves — CodingKeys is an explicit
        // enum precisely so this shape can't drift silently via a rename of
        // a stored property (memberwise-derived keys would follow the
        // property name automatically and this test wouldn't catch it).
        let record = APIEndpointRecord(
            id: UUID(),
            name: "Custom Endpoint",
            provider: .custom,
            baseURL: "https://example.com",
            modelName: "local-model",
            keychainAccount: "acct",
            createdAt: Date(timeIntervalSince1970: 0),
            isEnabled: true
        )

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expectedKeys: Set<String> = [
            "id", "name", "provider", "baseURL", "modelName",
            "keychainAccount", "createdAt", "isEnabled",
        ]
        XCTAssertEqual(Set(json.keys), expectedKeys)
    }

    // MARK: - Legacy provider-string migration (Wave 2 A1)

    /// JSON written by a pre-0.68 build persisted the provider *display* string
    /// (`"OpenAI Responses"`). It must still decode to the real provider, not
    /// throw or collapse.
    func test_legacyDisplayStringProvider_decodes() throws {
        let id = UUID()
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "name": "My Responses",
            "provider": "OpenAI Responses",
            "baseURL": "https://api.openai.com",
            "modelName": "gpt-5",
            "keychainAccount": "acct-legacy",
            "createdAt": 0,
            "isEnabled": true
        }
        """
        let decoded = try JSONDecoder().decode(
            APIEndpointRecord.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.provider, .openAIResponses,
                       "Legacy display string should map to the real provider")

        // Re-encoding emits the stable opaque code, not the legacy display string.
        let reencoded = try JSONEncoder().encode(decoded)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(json["provider"] as? String, "openAIResponses",
                       "Encoding must write the stable code, never the display string")
    }

    /// An unrecognised provider string is a routing hazard, so decode throws
    /// rather than silently falling back.
    func test_unknownProviderString_throws() {
        let json = """
        { "id": "\(UUID().uuidString)", "name": "x", "provider": "NotAProvider",
          "baseURL": "https://example.com", "modelName": "m",
          "keychainAccount": "a", "createdAt": 0, "isEnabled": true }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(APIEndpointRecord.self, from: Data(json.utf8))
        )
    }
}
