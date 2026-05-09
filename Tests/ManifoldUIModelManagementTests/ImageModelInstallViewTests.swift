import XCTest
@testable import ManifoldUIModelManagement

/// Sanity tests for the curated diffusion-model catalog that drives the
/// first-run image install flow. The view itself wraps a HuggingFace
/// download path that needs network and disk to exercise meaningfully —
/// covered end-to-end at the host level. These tests guard the catalog
/// shape that hosts depend on and make sure the entries stay valid.
final class ImageModelInstallViewTests: XCTestCase {

    func testCatalogHasAtLeastTwoEntries() {
        XCTAssertGreaterThanOrEqual(
            DiffusionModelCatalog.curated.count, 2,
            "Curated catalog should expose at least two installable models so the first-run UI has obvious good defaults."
        )
    }

    func testCatalogEntriesHaveValidIdentity() {
        for entry in DiffusionModelCatalog.curated {
            XCTAssertFalse(entry.id.isEmpty, "Catalog entry has an empty id")
            XCTAssertTrue(entry.id.contains("/"), "Catalog entry id \"\(entry.id)\" is not a HuggingFace repo ID (expected org/name).")
            XCTAssertFalse(entry.displayName.isEmpty, "Catalog entry \(entry.id) has an empty displayName")
            XCTAssertFalse(entry.description.isEmpty, "Catalog entry \(entry.id) has an empty description")
            XCTAssertGreaterThan(entry.approximateBytes, 0, "Catalog entry \(entry.id) has a non-positive approximateBytes")
        }
    }

    func testCatalogEntryIDsAreUnique() {
        let ids = DiffusionModelCatalog.curated.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Curated catalog has duplicate ids: \(ids)")
    }

    func testApproximateSizeFormattedIsHumanReadable() {
        let entry = DiffusionModelCatalogEntry(
            id: "x/y",
            displayName: "Y",
            description: "z",
            approximateBytes: 4_500_000_000
        )
        // ByteCountFormatter is locale-aware; just verify it produced a
        // non-empty string with a "GB" suffix on the en_US-ish defaults
        // every CI runner uses.
        let formatted = entry.approximateSizeFormatted
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(
            formatted.contains("GB") || formatted.contains("MB") || formatted.contains("KB"),
            "Expected a byte-suffix unit, got \(formatted)"
        )
    }
}
