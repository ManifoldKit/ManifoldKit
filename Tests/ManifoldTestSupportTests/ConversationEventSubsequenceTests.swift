import XCTest
import Foundation
@testable import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - ConversationEventSubsequenceTests

/// Unit tests for ``XCTAssertEventSubsequence(_:contains:file:line:)`` and
/// ``ConversationEventKind``.
final class ConversationEventSubsequenceTests: XCTestCase {

    // MARK: - Helpers

    private static func message(role: MessageRole = .user) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            content: "hello",
            sessionID: UUID()
        )
    }

    private static func makeSlot() -> PromptSlot {
        PromptSlot(
            id: UUID().uuidString,
            content: "ctx",
            label: "test"
        )
    }

    private static func makeToolCall() -> ToolCall {
        ToolCall(id: UUID().uuidString, toolName: "search", arguments: "{}")
    }

    // MARK: - Subsequence assertion tests

    /// Exact match — every kind appears once in the same order.
    func test_assertSubsequence_passes_when_exact_match() {
        let trace: [ConversationEvent] = [
            .streamStarted(messageID: UUID()),
            .tokenEmitted(messageID: UUID(), delta: "hi"),
            .streamFinished(messageID: UUID(), reason: .stop),
        ]
        XCTAssertEventSubsequence(trace, contains: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ])
    }

    /// Gaps between matched kinds are silently ignored.
    func test_assertSubsequence_passes_with_gaps() {
        let sessionID = UUID()
        let trace: [ConversationEvent] = [
            .beforeContextAssembly(prompt: nil, request: PromptContextRequest(sessionID: sessionID, messageCount: 0, userInput: nil)),
            .contextAssembled(slots: [Self.makeSlot()]),
            .streamStarted(messageID: UUID()),
            .tokenEmitted(messageID: UUID(), delta: "t1"),
            .tokenEmitted(messageID: UUID(), delta: "t2"),
            .streamFinished(messageID: UUID(), reason: .stop),
            .afterGeneration(messageID: UUID(), finalText: "t1t2"),
        ]
        // Verify that the interleaved tokenEmitted events don't block matching
        // the terminal pair.
        XCTAssertEventSubsequence(trace, contains: [
            .contextAssembled,
            .streamStarted,
            .streamFinished,
        ])
    }

    /// A kind can be required multiple times; the matcher finds each in order.
    func test_assertSubsequence_passes_repeated_kind() {
        let sessionID = UUID()
        let slots = [Self.makeSlot()]
        let trace: [ConversationEvent] = [
            .contextAssembled(slots: slots),
            .streamFinished(messageID: UUID(), reason: .stop),
            .contextAssembled(slots: slots),
        ]
        XCTAssertEventSubsequence(trace, contains: [
            .contextAssembled,
            .contextAssembled,
        ])
    }

    /// A required kind that never appears triggers a test failure.
    func test_assertSubsequence_fails_when_kind_absent() {
        let trace: [ConversationEvent] = [
            .streamStarted(messageID: UUID()),
            .streamFinished(messageID: UUID(), reason: .stop),
        ]
        // The assertion should fail because .tokenEmitted is never in the trace.
        XCTExpectFailure("tokenEmitted is absent from the trace") {
            XCTAssertEventSubsequence(trace, contains: [
                .streamStarted,
                .tokenEmitted,
                .streamFinished,
            ])
        }
    }

    /// Kinds required in the wrong order (relative to the trace) trigger failure.
    func test_assertSubsequence_fails_when_out_of_order() {
        let trace: [ConversationEvent] = [
            .streamStarted(messageID: UUID()),
            .streamFinished(messageID: UUID(), reason: .stop),
        ]
        // streamFinished before streamStarted cannot be matched left-to-right.
        XCTExpectFailure("streamStarted appears after streamFinished in the required sequence") {
            XCTAssertEventSubsequence(trace, contains: [
                .streamFinished,
                .streamStarted,
            ])
        }
    }

    // MARK: - Exhaustiveness sabotage check

    /// For every ``ConversationEventKind`` case, construct a representative
    /// ``ConversationEvent`` and assert that `.kind` returns the expected value.
    ///
    /// This test will not compile if a new case is added to ``ConversationEvent``
    /// without a matching update to the `kind` computed property (the switch
    /// in `ConversationEvent.kind` must be exhaustive).
    func test_conversationEventKind_exhaustive() {
        let sessionID = UUID()
        let messageID = UUID()
        let toolCall = Self.makeToolCall()
        let toolResult = ToolResult(callId: toolCall.id, content: "ok")
        let message = Self.message(role: .assistant)

        let pairs: [(ConversationEvent, ConversationEventKind)] = [
            (.messageInserted(message), .messageInserted),
            (.messageRemoved(messageID: messageID), .messageRemoved),
            (.messageUpdated(message), .messageUpdated),
            (.sessionBranched(newSessionID: sessionID, copiedCount: 3), .sessionBranched),
            (.streamStarted(messageID: messageID), .streamStarted),
            (.tokenEmitted(messageID: messageID, delta: "hi"), .tokenEmitted),
            (.tokenUsageRecorded(messageID: messageID, promptTokens: 10, completionTokens: 5), .tokenUsageRecorded),
            (.thinkingStarted(messageID: messageID), .thinkingStarted),
            (.thinkingUpdated(messageID: messageID, partialText: "..."), .thinkingUpdated),
            (.thinkingFinalized(messageID: messageID, text: "done", signature: nil), .thinkingFinalized),
            (.loopDetected(messageID: messageID), .loopDetected),
            (.streamFinished(messageID: messageID, reason: .stop), .streamFinished),
            (.errorRaised(.providerNotConfigured), .errorRaised),
            (.sessionTouchFailed(sessionID: sessionID), .sessionTouchFailed),
            (.beforeContextAssembly(prompt: nil, request: PromptContextRequest(sessionID: sessionID, messageCount: 0, userInput: nil)), .beforeContextAssembly),
            (.historyShaped(sessionID: sessionID, diagnostics: []), .historyShaped),
            (.contextAssembled(slots: []), .contextAssembled),
            (.afterGeneration(messageID: messageID, finalText: "done"), .afterGeneration),
            (.compressionTriggered(removed: [], reason: .contextWindowExceeded), .compressionTriggered),
            (.historyCompressed(sessionID: sessionID, insertedRecords: []), .historyCompressed),
            (.toolCallRequested(toolCall), .toolCallRequested),
            (.toolCallApproved(toolCall.id), .toolCallApproved),
            (.toolCallCompleted(toolCall.id, toolResult), .toolCallCompleted),
            (.agentHandoff(from: nil, to: sessionID), .agentHandoff),
            (.skillInvoked(name: "summarise", sessionID: sessionID), .skillInvoked),
            (.hookFired(event: "preToolUse", sessionID: sessionID), .hookFired),
        ]

        // Verify count matches CaseIterable so a missing pair is caught here
        // even if the switch somehow remains exhaustive.
        XCTAssertEqual(pairs.count, ConversationEventKind.allCases.count,
                       "pairs count must match ConversationEventKind.allCases.count — add the missing case")

        for (event, expectedKind) in pairs {
            XCTAssertEqual(event.kind, expectedKind,
                           "event \(event) had kind \(event.kind.rawValue), expected \(expectedKind.rawValue)")
        }
    }
}
