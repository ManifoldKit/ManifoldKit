// MARK: - ConversationEventKind

/// The kind of a ``ConversationEvent``, stripped of associated values.
///
/// Used as the stable key in JSONL trace files and as the discriminant in
/// ``XCTAssertEventSubsequence(_:contains:file:line:)``.
///
/// ## Wire-contract posture
///
/// The `String` raw value of every existing case is a **persisted JSONL
/// trace contract**: it is written to disk today and must remain decodable
/// tomorrow. Existing raw values are therefore **immutable** — never renamed
/// or renumbered, even in a MAJOR release, because that would silently
/// corrupt the meaning of already-written trace files rather than merely
/// fail to compile. New kinds are **append-only**: adding a case (and its
/// raw value) alongside ``ConversationEvent`` growing a new case is a MINOR
/// change, consistent with ``ConversationEvent``'s own open-pre-and-post-1.0
/// posture. Trace **readers** (anything decoding `ConversationEventKind`
/// from a persisted JSONL trace, as opposed to code that switches over a
/// freshly-constructed value) must tolerate an unknown kind string —
/// decoding to `nil` / skipping the line — rather than throwing, so a trace
/// written by a newer ManifoldKit stays readable by an older reader.
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
    case hookFired
}
