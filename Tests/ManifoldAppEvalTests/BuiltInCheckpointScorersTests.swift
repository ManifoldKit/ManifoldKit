import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldAppEval

// MARK: - BuiltInCheckpointScorersTests

/// Positive / negative / absence coverage for every built-in checkpoint
/// scorer in ``BuiltInCheckpointScorers``.
final class BuiltInCheckpointScorersTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext(
        checkpoint: GoldenCheckpoint,
        visibleText: String = "",
        toolCalls: [ToolCall] = [],
        eventKinds: [ConversationEventKind] = [],
        producedMessageCount: Int = 0,
        lastContextAssembledSlotCount: Int? = nil,
        lastCompressionInsertedRecordCount: Int? = nil
    ) -> CheckpointEvaluationContext {
        CheckpointEvaluationContext(
            output: EvalRunOutput(visibleText: visibleText, toolCalls: toolCalls),
            snapshot: nil,
            checkpoint: checkpoint,
            eventKinds: eventKinds,
            producedMessageCount: producedMessageCount,
            lastContextAssembledSlotCount: lastContextAssembledSlotCount,
            lastCompressionInsertedRecordCount: lastCompressionInsertedRecordCount
        )
    }

    // MARK: - requiredContent

    func test_requiredContent_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        let context = makeContext(checkpoint: checkpoint)
        XCTAssertNil(BuiltInCheckpointScorers.scoreRequiredContent(context))
    }

    func test_requiredContent_passes_whenAllSubstringsPresent() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, requiredContent: ["hello", "world"])
        let context = makeContext(checkpoint: checkpoint, visibleText: "hello, world!")
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreRequiredContent(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_requiredContent_fails_whenSubstringMissing() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, requiredContent: ["goodbye"])
        let context = makeContext(checkpoint: checkpoint, visibleText: "hello")
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreRequiredContent(context))
        XCTAssertEqual(score.value, .bool(false))
        XCTAssertNotNil(score.explanation)
    }

    // MARK: - forbiddenContent

    func test_forbiddenContent_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        XCTAssertNil(BuiltInCheckpointScorers.scoreForbiddenContent(makeContext(checkpoint: checkpoint)))
    }

    func test_forbiddenContent_passes_whenAbsent() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, forbiddenContent: ["goodbye"])
        let context = makeContext(checkpoint: checkpoint, visibleText: "hello")
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreForbiddenContent(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_forbiddenContent_fails_whenPresent() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, forbiddenContent: ["hello"])
        let context = makeContext(checkpoint: checkpoint, visibleText: "hello there")
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreForbiddenContent(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    // MARK: - expectedEvents

    func test_expectedEvents_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        XCTAssertNil(BuiltInCheckpointScorers.scoreExpectedEvents(makeContext(checkpoint: checkpoint)))
    }

    func test_expectedEvents_passes_whenSubsequenceMatches() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, expectedEvents: ["streamStarted", "streamFinished"])
        let context = makeContext(
            checkpoint: checkpoint,
            eventKinds: [.streamStarted, .tokenEmitted, .streamFinished]
        )
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedEvents(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_expectedEvents_fails_whenMissing() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, expectedEvents: ["toolCallRequested"])
        let context = makeContext(checkpoint: checkpoint, eventKinds: [.streamStarted, .streamFinished])
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedEvents(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    func test_expectedEvents_unavailable_whenRawValueInvalid() throws {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0, expectedEvents: ["notARealKind"])
        let context = makeContext(checkpoint: checkpoint, eventKinds: [.streamStarted])
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedEvents(context))
        XCTAssertEqual(score.value, .unavailable)
    }

    // MARK: - expectedToolCalls

    func test_expectedToolCalls_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        XCTAssertNil(BuiltInCheckpointScorers.scoreExpectedToolCalls(makeContext(checkpoint: checkpoint)))
    }

    func test_expectedToolCalls_passes_whenNameAndArgumentsMatch() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedToolCalls: [GoldenExpectedToolCall(name: "echo", argumentsContain: ["text": "hel"])]
        )
        let call = ToolCall(id: "1", toolName: "echo", arguments: #"{"text":"hello"}"#)
        let context = makeContext(checkpoint: checkpoint, toolCalls: [call])
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedToolCalls(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_expectedToolCalls_fails_whenToolNotCalled() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedToolCalls: [GoldenExpectedToolCall(name: "echo")]
        )
        let context = makeContext(checkpoint: checkpoint, toolCalls: [])
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedToolCalls(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    func test_expectedToolCalls_fails_whenArgumentSubstringMissing() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedToolCalls: [GoldenExpectedToolCall(name: "echo", argumentsContain: ["text": "goodbye"])]
        )
        let call = ToolCall(id: "1", toolName: "echo", arguments: #"{"text":"hello"}"#)
        let context = makeContext(checkpoint: checkpoint, toolCalls: [call])
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedToolCalls(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    // MARK: - expectedCompression

    func test_expectedCompression_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        XCTAssertNil(BuiltInCheckpointScorers.scoreExpectedCompression(makeContext(checkpoint: checkpoint)))
    }

    func test_expectedCompression_passes_whenWithinBounds() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedCompression: GoldenExpectedCompression(maxRetainedMessages: 3, minInsertedRecords: 1)
        )
        let context = makeContext(
            checkpoint: checkpoint,
            producedMessageCount: 3,
            lastCompressionInsertedRecordCount: 1
        )
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedCompression(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_expectedCompression_fails_whenTooManyMessagesRetained() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedCompression: GoldenExpectedCompression(maxRetainedMessages: 2)
        )
        let context = makeContext(checkpoint: checkpoint, producedMessageCount: 5)
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedCompression(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    func test_expectedCompression_unavailable_whenNoCompressionEventYetButMinInsertedDeclared() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedCompression: GoldenExpectedCompression(minInsertedRecords: 1)
        )
        let context = makeContext(checkpoint: checkpoint, lastCompressionInsertedRecordCount: nil)
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedCompression(context))
        XCTAssertEqual(score.value, .unavailable)
    }

    /// The failure-masking regression case: maxRetainedMessages VIOLATED
    /// (a definitive failure) while minInsertedRecords is indeterminate (no
    /// historyCompressed event yet). The accrued failure must win — never be
    /// discarded in favour of `.unavailable`.
    func test_expectedCompression_accruedFailureNotMaskedByIndeterminateMinInserted() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedCompression: GoldenExpectedCompression(maxRetainedMessages: 2, minInsertedRecords: 1)
        )
        let context = makeContext(
            checkpoint: checkpoint,
            producedMessageCount: 5,                    // violates maxRetainedMessages: 2
            lastCompressionInsertedRecordCount: nil     // minInsertedRecords indeterminate
        )
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedCompression(context))
        XCTAssertEqual(score.value, .bool(false), "a proven failure must never be masked as absence")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("retained 5 messages"), explanation)
        XCTAssertTrue(explanation.contains("indeterminate"), "the un-measured sub-assertion should still be surfaced: \(explanation)")
    }

    /// Precedence completeness: a PASSING sub-assertion plus an indeterminate
    /// one yields `.unavailable`, not a pass — a full pass can't be claimed
    /// while part of the declaration was never measured.
    func test_expectedCompression_passPlusIndeterminate_yieldsUnavailable() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedCompression: GoldenExpectedCompression(maxRetainedMessages: 10, minInsertedRecords: 1)
        )
        let context = makeContext(
            checkpoint: checkpoint,
            producedMessageCount: 3,                    // satisfies maxRetainedMessages: 10
            lastCompressionInsertedRecordCount: nil     // minInsertedRecords indeterminate
        )
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedCompression(context))
        XCTAssertEqual(score.value, .unavailable)
    }

    // MARK: - expectedContextSlots

    func test_expectedContextSlots_absent_whenNotDeclared() {
        let checkpoint = GoldenCheckpoint(afterTurnIndex: 0)
        XCTAssertNil(BuiltInCheckpointScorers.scoreExpectedContextSlots(makeContext(checkpoint: checkpoint)))
    }

    func test_expectedContextSlots_passes_whenWithinBounds() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedContextSlots: GoldenExpectedContextSlots(minSlots: 1, maxSlots: 3)
        )
        let context = makeContext(checkpoint: checkpoint, lastContextAssembledSlotCount: 2)
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedContextSlots(context))
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_expectedContextSlots_fails_whenBelowMinimum() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedContextSlots: GoldenExpectedContextSlots(minSlots: 2)
        )
        let context = makeContext(checkpoint: checkpoint, lastContextAssembledSlotCount: 1)
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedContextSlots(context))
        XCTAssertEqual(score.value, .bool(false))
    }

    func test_expectedContextSlots_unavailable_whenNoContextAssembledYet() throws {
        let checkpoint = GoldenCheckpoint(
            afterTurnIndex: 0,
            expectedContextSlots: GoldenExpectedContextSlots(minSlots: 1)
        )
        let context = makeContext(checkpoint: checkpoint, lastContextAssembledSlotCount: nil)
        let score = try XCTUnwrap(BuiltInCheckpointScorers.scoreExpectedContextSlots(context))
        XCTAssertEqual(score.value, .unavailable)
    }
}
