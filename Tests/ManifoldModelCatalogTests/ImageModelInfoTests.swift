import XCTest
import ManifoldInference
@testable import ManifoldModelCatalog

final class ImageModelInfoTests: XCTestCase {

    // MARK: - Helpers

    private func makeInfo(
        id: String = "stabilityai/sdxl-turbo",
        name: String = "SDXL Turbo",
        directoryURL: URL = URL(fileURLWithPath: "/tmp/models/sdxl-turbo"),
        format: ImageModelFormat = .mlxDiffusion,
        fileSize: Int64 = 4_200_000_000,
        huggingFaceRepoID: String? = "stabilityai/sdxl-turbo"
    ) -> ImageModelInfo {
        ImageModelInfo(
            id: id,
            name: name,
            directoryURL: directoryURL,
            format: format,
            fileSize: fileSize,
            huggingFaceRepoID: huggingFaceRepoID
        )
    }

    // MARK: - Codable

    func test_codable_roundTrip_withHuggingFaceRepoID() throws {
        let original = makeInfo(huggingFaceRepoID: "stabilityai/sdxl-turbo")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageModelInfo.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.huggingFaceRepoID, "stabilityai/sdxl-turbo")
    }

    func test_codable_roundTrip_withNilHuggingFaceRepoID() throws {
        let original = makeInfo(huggingFaceRepoID: nil)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageModelInfo.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.huggingFaceRepoID)
    }

    // MARK: - Equatable / Hashable

    func test_equatable_sameFields_areEqual() {
        let a = makeInfo()
        let b = makeInfo()

        XCTAssertEqual(a, b)
    }

    func test_hashable_sameFields_haveSameHash() {
        let a = makeInfo()
        let b = makeInfo()

        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_equatable_differentID_notEqual() {
        let a = makeInfo(id: "first")
        let b = makeInfo(id: "second")

        XCTAssertNotEqual(a, b)
    }

    // MARK: - Identifiable

    func test_identifiable_idMatchesIDField() {
        let info = makeInfo(id: "my-id")

        // `id` requirement of Identifiable resolves to the stored `id` property.
        XCTAssertEqual(info.id, "my-id")
    }

    // MARK: - Format

    func test_format_mlxDiffusion_persistsAcrossCodableRoundTrip() throws {
        let original = makeInfo(format: .mlxDiffusion)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageModelInfo.self, from: data)

        XCTAssertEqual(decoded.format, .mlxDiffusion)
    }
}
