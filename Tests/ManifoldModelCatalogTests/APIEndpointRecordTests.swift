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
}
