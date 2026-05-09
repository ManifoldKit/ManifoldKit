import XCTest
@testable import ManifoldUI
@testable import ManifoldInference

/// Unit tests for the pure `MemoryPressureResponder` action tree extracted from
/// `ChatViewModel.handleMemoryPressure()`.
final class MemoryPressureResponderTests: XCTestCase {

    private let responder = MemoryPressureResponder()

    // MARK: - Same level returns no actions

    func testSameLevelReturnsEmpty() {
        XCTAssertTrue(responder.actions(for: .nominal, lastLevel: .nominal).isEmpty)
        XCTAssertTrue(responder.actions(for: .warning, lastLevel: .warning).isEmpty)
        XCTAssertTrue(responder.actions(for: .critical, lastLevel: .critical).isEmpty)
    }

    // MARK: - Warning

    func testWarningReturnsSetErrorWithoutUnload() {
        let actions = responder.actions(for: .warning, lastLevel: .nominal)
        XCTAssertEqual(actions.count, 1)
        guard case let .setError(error) = actions[0] else {
            XCTFail("expected .setError action, got \(actions[0])")
            return
        }
        XCTAssertEqual(error.kind, .memoryPressure)
        XCTAssertEqual(error.recovery, .dismissOnly)
        XCTAssertTrue(error.message.contains("elevated"))

        // Crucially: no stop/unload on a warning.
        for action in actions {
            switch action {
            case .stopGeneration, .unloadModel:
                XCTFail("warning must not stop generation or unload")
            default:
                break
            }
        }
    }

    // MARK: - Critical

    func testCriticalReturnsStopUnloadAndError() {
        let actions = responder.actions(for: .critical, lastLevel: .warning)
        XCTAssertEqual(actions.count, 3)

        // Order matters — the original VM called stopGeneration() and
        // unloadModel() *before* assigning activeError.
        guard case .stopGeneration = actions[0] else {
            XCTFail("first action must be .stopGeneration, got \(actions[0])")
            return
        }
        guard case .unloadModel = actions[1] else {
            XCTFail("second action must be .unloadModel, got \(actions[1])")
            return
        }
        guard case let .setError(error) = actions[2] else {
            XCTFail("third action must be .setError, got \(actions[2])")
            return
        }
        XCTAssertEqual(error.kind, .memoryPressure)
        XCTAssertTrue(error.message.contains("critical"))
    }

    // MARK: - Recovery to nominal

    func testNominalAfterWarningReturnsClearError() {
        let actions = responder.actions(for: .nominal, lastLevel: .warning)
        XCTAssertEqual(actions.count, 1)
        guard case .clearMemoryPressureError = actions[0] else {
            XCTFail("expected .clearMemoryPressureError, got \(actions[0])")
            return
        }
    }

    func testNominalAfterCriticalReturnsClearError() {
        let actions = responder.actions(for: .nominal, lastLevel: .critical)
        XCTAssertEqual(actions.count, 1)
        guard case .clearMemoryPressureError = actions[0] else {
            XCTFail("expected .clearMemoryPressureError, got \(actions[0])")
            return
        }
    }
}
