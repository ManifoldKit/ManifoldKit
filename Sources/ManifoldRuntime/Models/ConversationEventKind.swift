// MARK: - ConversationEventKind

/// The kind of a ``ConversationEvent``, stripped of associated values.
///
/// Used as the stable key in JSONL trace files and as the discriminant in
/// ``XCTAssertEventSubsequence(_:contains:file:line:)``.
public enum ConversationEventKind: String, Codable, Sendable, CaseIterable {
    case messageInserted
    case messageRemoved
    case messageUpdated
    case sessionBranched
    case streamStarted
    case tokenEmitted
    case tokenUsageRecorded
    case thinkingStarted
    case thinkingUpdated
    case thinkingFinalized
    case loopDetected
    case streamFinished
    case errorRaised
    case sessionTouchFailed
    case beforeContextAssembly
    case historyShaped
    case contextAssembled
    case afterGeneration
    case compressionTriggered
    case historyCompressed
    case toolCallRequested
    case toolCallApproved
    case toolCallCompleted
    case agentHandoff
    case skillInvoked
    case hookFired
}
