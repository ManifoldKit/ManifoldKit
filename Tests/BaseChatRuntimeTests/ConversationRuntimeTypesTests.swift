import XCTest
@testable import BaseChatRuntime
import BaseChatInference

/// Exhaustive value-equality and hashable coverage for the small public types
/// declared in `ConversationRuntimeTypes.swift` (``FinishReason``,
/// ``CompressionReason``, ``PromptContextRequest``). These types are part of
/// the runtime's public event surface — locking their case set and equality
/// semantics catches accidental ABI breakage at compile + test time.
final class ConversationRuntimeTypesTests: XCTestCase {

    // MARK: - FinishReason

    func test_finishReason_allCases_haveDistinctEquality() {
        let cases: [FinishReason] = [.stop, .cancelled, .empty, .length]
        for (i, lhs) in cases.enumerated() {
            for (j, rhs) in cases.enumerated() {
                if i == j {
                    XCTAssertEqual(lhs, rhs, "\(lhs) must equal itself")
                } else {
                    XCTAssertNotEqual(lhs, rhs, "\(lhs) must not equal \(rhs)")
                }
            }
        }
    }

    /// Compile-time guard: switching exhaustively on `FinishReason` must
    /// remain exhaustive. Adding a case without updating this switch will
    /// fail to compile, surfacing the new case at review time.
    func test_finishReason_switchExhaustiveness_compilesForAllCases() {
        func describe(_ reason: FinishReason) -> String {
            switch reason {
            case .stop: return "stop"
            case .cancelled: return "cancelled"
            case .empty: return "empty"
            case .length: return "length"
            }
        }
        XCTAssertEqual(describe(.stop), "stop")
        XCTAssertEqual(describe(.cancelled), "cancelled")
        XCTAssertEqual(describe(.empty), "empty")
        XCTAssertEqual(describe(.length), "length")
    }

    // MARK: - CompressionReason

    func test_compressionReason_distinctEquality() {
        XCTAssertEqual(CompressionReason.contextWindowExceeded, .contextWindowExceeded)
        XCTAssertEqual(CompressionReason.manual, .manual)
        XCTAssertNotEqual(CompressionReason.contextWindowExceeded, .manual)
    }

    func test_compressionReason_switchExhaustiveness_compilesForAllCases() {
        func describe(_ reason: CompressionReason) -> String {
            switch reason {
            case .contextWindowExceeded: return "context"
            case .manual: return "manual"
            }
        }
        XCTAssertEqual(describe(.contextWindowExceeded), "context")
        XCTAssertEqual(describe(.manual), "manual")
    }

    // MARK: - PromptContextRequest

    func test_promptContextRequest_storesAllFields() {
        let id = UUID()
        let request = PromptContextRequest(sessionID: id, messageCount: 7, userInput: "hi")
        XCTAssertEqual(request.sessionID, id)
        XCTAssertEqual(request.messageCount, 7)
        XCTAssertEqual(request.userInput, "hi")
    }

    func test_promptContextRequest_equatable_byValue() {
        let id = UUID()
        let a = PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        let b = PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_promptContextRequest_inequality_anyFieldDifferent() {
        let id = UUID()
        let base = PromptContextRequest(sessionID: id, messageCount: 3, userInput: "x")

        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: UUID(), messageCount: 3, userInput: "x")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 4, userInput: "x")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 3, userInput: "y")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        )
    }

    func test_promptContextRequest_userInputNil_isPreserved() {
        let request = PromptContextRequest(sessionID: UUID(), messageCount: 0, userInput: nil)
        XCTAssertNil(request.userInput)
    }
}
