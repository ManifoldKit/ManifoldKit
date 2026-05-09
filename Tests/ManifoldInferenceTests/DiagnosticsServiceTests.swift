import XCTest
@testable import ManifoldInference

@MainActor
final class DiagnosticsServiceTests: XCTestCase {

    func test_record_appendsToWarningsNewestFirst() {
        let service = DiagnosticsService()
        service.record(.benchmarkCacheUnavailable(reason: "first"))
        service.record(.benchmarkCacheUnavailable(reason: "second"))

        XCTAssertEqual(service.count, 2)
        XCTAssertEqual(service.warnings.first?.error, .benchmarkCacheUnavailable(reason: "second"))
        XCTAssertEqual(service.warnings.last?.error, .benchmarkCacheUnavailable(reason: "first"))
    }

    func test_record_duplicateCasesRetainDistinctIdentity() {
        let service = DiagnosticsService()
        service.record(.benchmarkCacheUnavailable(reason: "same"))
        service.record(.benchmarkCacheUnavailable(reason: "same"))

        XCTAssertEqual(service.count, 2)
        XCTAssertNotEqual(service.warnings[0].id, service.warnings[1].id)
    }

    func test_dismiss_removesMatchingWarning() {
        let service = DiagnosticsService()
        service.record(.benchmarkCacheUnavailable(reason: "a"))
        service.record(.benchmarkCacheUnavailable(reason: "b"))
        let victim = service.warnings[0]

        service.dismiss(victim.id)

        XCTAssertEqual(service.count, 1)
        XCTAssertFalse(service.warnings.contains { $0.id == victim.id })
    }

    func test_dismiss_unknownIDIsNoOp() {
        let service = DiagnosticsService()
        service.record(.benchmarkCacheUnavailable(reason: "a"))

        service.dismiss(UUID())

        XCTAssertEqual(service.count, 1)
    }

    func test_dismissAll_clearsWarnings() {
        let service = DiagnosticsService()
        service.record(.benchmarkCacheUnavailable(reason: "a"))
        service.record(.benchmarkCacheUnavailable(reason: "b"))

        service.dismissAll()

        XCTAssertTrue(service.isEmpty)
    }

    func test_capacity_evictsOldestWarningsPastCap() {
        let service = DiagnosticsService(capacity: 3)
        for i in 0..<5 {
            service.record(.benchmarkCacheUnavailable(reason: "\(i)"))
        }

        XCTAssertEqual(service.count, 3)
        // Newest first: "4", "3", "2" — "0" and "1" should have been evicted.
        XCTAssertEqual(service.warnings[0].error, .benchmarkCacheUnavailable(reason: "4"))
        XCTAssertEqual(service.warnings[2].error, .benchmarkCacheUnavailable(reason: "2"))
    }

    func test_capacity_zeroIsClampedToOne() {
        // A zero cap would drop every record, defeating the purpose — clamp to 1.
        let service = DiagnosticsService(capacity: 0)
        service.record(.benchmarkCacheUnavailable(reason: "x"))

        XCTAssertEqual(service.count, 1)
    }

    func test_isEmpty_trueOnInit() {
        let service = DiagnosticsService()
        XCTAssertTrue(service.isEmpty)
        XCTAssertEqual(service.count, 0)
    }
}
