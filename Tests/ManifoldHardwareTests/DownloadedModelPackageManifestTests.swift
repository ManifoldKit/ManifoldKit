import XCTest
@testable import ManifoldHardware

/// Codable round-trip and backward-compatibility coverage for
/// ``DownloadedModelPackageManifest``, focused on the optional
/// `chatTemplateSHA256` field added for chat-template integrity (#1932).
final class DownloadedModelPackageManifestTests: XCTestCase {

    private func roundTrip(_ manifest: DownloadedModelPackageManifest) throws -> DownloadedModelPackageManifest {
        let data = try JSONEncoder().encode(manifest)
        return try JSONDecoder().decode(DownloadedModelPackageManifest.self, from: data)
    }

    /// A manifest carrying a hash survives an encode/decode round-trip intact.
    func test_roundTrip_withChatTemplateHash() throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .mlxSnapshot,
            id: "org/model",
            displayName: "Model",
            files: ["config.json", "model.safetensors"],
            chatTemplateSHA256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )

        let decoded = try roundTrip(manifest)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(
            decoded.chatTemplateSHA256,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    /// A manifest with no hash round-trips with the field nil.
    func test_roundTrip_withoutChatTemplateHash() throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .diffusion,
            id: "org/diffusion",
            displayName: "Diffusion",
            files: ["model_index.json"]
        )

        let decoded = try roundTrip(manifest)

        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.chatTemplateSHA256)
    }

    /// **Backward compat:** a pre-#1932 sidecar payload that predates the
    /// `chatTemplateSHA256` key must still decode, leaving the field nil.
    func test_legacyPayloadWithoutField_stillDecodes() throws {
        let legacyJSON = """
        {
          "packageKind": "mlxSnapshot",
          "id": "org/legacy",
          "displayName": "Legacy",
          "files": ["config.json", "model.safetensors"]
        }
        """

        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(DownloadedModelPackageManifest.self, from: data)

        XCTAssertEqual(decoded.id, "org/legacy")
        XCTAssertEqual(decoded.files, ["config.json", "model.safetensors"])
        XCTAssertNil(decoded.chatTemplateSHA256, "Legacy payloads must decode with a nil hash, not fail")
    }
}
