import XCTest
@testable import ManifoldInference

final class ScoreTests: XCTestCase {

    func testDoubleValueForNumber() {
        XCTAssertEqual(ScoreValue.number(0.42).doubleValue, 0.42)
    }

    func testDoubleValueForBool() {
        XCTAssertEqual(ScoreValue.bool(true).doubleValue, 1)
        XCTAssertEqual(ScoreValue.bool(false).doubleValue, 0)
    }

    func testDoubleValueForUnavailableIsNil() {
        // The whole point of `unavailable`: it must NOT read as a numeric zero.
        XCTAssertNil(ScoreValue.unavailable.doubleValue)
    }

    func testCompactMapDropsUnavailable() {
        let scores: [Score] = [
            Score(value: .number(1.0)),
            Score(value: .unavailable),
            Score(value: .bool(true)),
        ]
        let numeric = scores.compactMap(\.value.doubleValue)
        XCTAssertEqual(numeric, [1.0, 1.0])
    }

    func testEquatable() {
        let a = Score(value: .bool(true), explanation: "matched", metadata: ["scorer": "x"])
        let b = Score(value: .bool(true), explanation: "matched", metadata: ["scorer": "x"])
        let c = Score(value: .bool(false), explanation: "matched", metadata: ["scorer": "x"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
