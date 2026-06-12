import XCTest
@testable import ManifoldFuzz

final class SmokeTests: XCTestCase {

    func test_corpusLoads() {
        let entries = Corpus.load()
        XCTAssertGreaterThan(entries.count, 0, "Bundled seeds.json should be readable as a resource")
    }

    func test_detectorRegistryHasDayOneDetectors() {
        let ids = DetectorRegistry.all.map(\.id)
        XCTAssertTrue(ids.contains("thinking-classification"))
        XCTAssertTrue(ids.contains("looping"))
        XCTAssertTrue(ids.contains("empty-output-after-work"))
    }

    func test_findingHashIsDeterministic() {
        let a = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        let b = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        XCTAssertEqual(a.hash, b.hash)
    }

    func test_findingHash_differsForDifferentInputs() {
        let base = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        let differentSubCheck = Finding(detectorId: "x", subCheck: "z", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        let differentTrigger = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "xyz", modelId: "m1", firstSeen: "t", count: 1)
        XCTAssertNotEqual(base.hash, differentSubCheck.hash, "subCheck must influence hash")
        XCTAssertNotEqual(base.hash, differentTrigger.hash, "trigger must influence hash")
    }
}
