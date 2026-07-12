import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Compile-time tripwire enforcing invariant 6 from the target-architecture
/// plan (docs/plans/archive/target-architecture.md, removed in a 2026-07
/// docs/plans hygiene pass — see git history):
///
/// > "New modality/run-level events ride their own event types — never new
/// > `GenerationEvent` cases on the text path."
///
/// Run-level lifecycle events (`runStarted`, `stepFailed`, `runCompleted`, …)
/// belong on ``RunEvent``, a sibling of ``ConversationEvent``. Adding a
/// run/step-shaped case to ``ConversationEvent`` would push unreachable arms
/// into the ~14 exhaustive `switch` consumers on the text path and silently
/// break the closed-switch contract.
///
/// The sibling ``GenerationEventClosedAuditTest`` checks the string-keyed
/// ``ConversationEventKind`` mirror. This file is the *structural* counterpart:
/// it forces a compile error on the `switch` in `caseName(for:)` whenever a
/// case is added to, removed from, or renamed on ``ConversationEvent`` itself —
/// so this file is the checkpoint a contributor must visit before any case
/// change lands. The asserted allowlist (`expectedCaseNames`) then documents
/// the exact surface and fails at runtime if a run/step-shaped name slips in.
///
/// What a failure means:
/// - **Compile error in `caseName(for:)` / `sampleEvents()`**: ``ConversationEvent``
///   changed. If the change adds a *run-level* case, move it to ``RunEvent``
///   instead. If it is a legitimate text-path case, add an arm + sample here
///   AND add the name to `expectedCaseNames`.
/// - **`test_noRunLevelShapedCaseNames` fails**: a run/step-lifecycle-shaped
///   name leaked onto the text path. Relocate it to ``RunEvent``.
///
/// The detection logic lives in ``reservedPrefixViolations(caseNames:)`` so
/// the in-file sabotage test exercises the exact function the audit runs.
final class ConversationEventClosedSwitchAuditTest: XCTestCase {

    // MARK: Reserved run-level vocabulary (owned by RunEvent, never ConversationEvent)

    /// Prefixes reserved for run-level lifecycle events. A ``ConversationEvent``
    /// case name starting with any of these is an invariant-6 violation.
    private static let reservedRunPrefixes = ["run", "step"]

    /// The exact, asserted set of ``ConversationEvent`` case names. This is the
    /// text-path event contract. It must stay in lock-step with the closed
    /// `switch` in `caseName(for:)` below.
    private static let expectedCaseNames: Set<String> = [
        // Lifecycle
        "messageInserted",
        "messageRemoved",
        "messageUpdated",
        "sessionBranched",
        "streamStarted",
        "tokenEmitted",
        "tokenUsageRecorded",
        "thinkingStarted",
        "thinkingUpdated",
        "thinkingFinalized",
        "loopDetected",
        "streamFinished",
        "errorRaised",
        "sessionTouchFailed",
        // Context pipeline
        "beforeContextAssembly",
        "historyShaped",
        "contextAssembled",
        "afterGeneration",
        "compressionTriggered",
        "historyCompressed",
        // Tool calls
        "toolCallRequested",
        "toolCallApproved",
        "toolCallCompleted",
        // Multi-agent / skills / hooks
        "agentHandoff",
        "skillInvoked",
        "hookFired",
    ]

    // MARK: Closed-switch checkpoint
    //
    // Exhaustive over EVERY current ``ConversationEvent`` case. Adding a case to
    // the enum without adding an arm here is a COMPILE ERROR — that is the
    // tripwire. The returned string is the case name, validated below.
    private func caseName(for event: ConversationEvent) -> String {
        switch event {
        case .messageInserted:       return "messageInserted"
        case .messageRemoved:        return "messageRemoved"
        case .messageUpdated:        return "messageUpdated"
        case .sessionBranched:       return "sessionBranched"
        case .streamStarted:         return "streamStarted"
        case .tokenEmitted:          return "tokenEmitted"
        case .tokenUsageRecorded:    return "tokenUsageRecorded"
        case .thinkingStarted:       return "thinkingStarted"
        case .thinkingUpdated:       return "thinkingUpdated"
        case .thinkingFinalized:     return "thinkingFinalized"
        case .loopDetected:          return "loopDetected"
        case .streamFinished:        return "streamFinished"
        case .errorRaised:           return "errorRaised"
        case .sessionTouchFailed:    return "sessionTouchFailed"
        case .beforeContextAssembly: return "beforeContextAssembly"
        case .historyShaped:         return "historyShaped"
        case .contextAssembled:      return "contextAssembled"
        case .afterGeneration:       return "afterGeneration"
        case .compressionTriggered:  return "compressionTriggered"
        case .historyCompressed:     return "historyCompressed"
        case .toolCallRequested:     return "toolCallRequested"
        case .toolCallApproved:      return "toolCallApproved"
        case .toolCallCompleted:     return "toolCallCompleted"
        case .agentHandoff:          return "agentHandoff"
        case .skillInvoked:          return "skillInvoked"
        case .hookFired:             return "hookFired"
        }
    }

    /// One sample value per ``ConversationEvent`` case. The closed `switch` in
    /// `caseName(for:)` plus this exhaustive sample list together force any enum
    /// change to surface here.
    private func sampleEvents() -> [ConversationEvent] {
        let messageID = UUID()
        let sessionID = UUID()
        return [
            .messageInserted(ChatMessage(role: .assistant, content: "", sessionID: sessionID)),
            .messageRemoved(messageID: messageID),
            .messageUpdated(ChatMessage(role: .assistant, content: "", sessionID: sessionID)),
            .sessionBranched(newSessionID: sessionID, copiedCount: 0),
            .streamStarted(messageID: messageID),
            .tokenEmitted(messageID: messageID, delta: ""),
            .tokenUsageRecorded(messageID: messageID, promptTokens: 0, completionTokens: 0),
            .thinkingStarted(messageID: messageID),
            .thinkingUpdated(messageID: messageID, partialText: ""),
            .thinkingFinalized(messageID: messageID, text: "", signature: nil),
            .loopDetected(messageID: messageID),
            .streamFinished(messageID: messageID, reason: .stop),
            .errorRaised(.cancelled),
            .sessionTouchFailed(sessionID: sessionID),
            .beforeContextAssembly(
                prompt: nil,
                request: PromptContextRequest(sessionID: sessionID, messageCount: 0, userInput: nil)
            ),
            .historyShaped(sessionID: sessionID, diagnostics: []),
            .contextAssembled(slots: []),
            .afterGeneration(messageID: messageID, finalText: ""),
            .compressionTriggered(removed: [], reason: .contextWindowExceeded),
            .historyCompressed(sessionID: sessionID, insertedRecords: []),
            .toolCallRequested(ToolCall(id: "t", toolName: "noop", arguments: "{}")),
            .toolCallApproved("t"),
            .toolCallCompleted("t", ToolResult(callId: "t", content: "")),
            .agentHandoff(from: nil, to: UUID()),
            .skillInvoked(name: "s", sessionID: sessionID),
            .hookFired(event: "preToolUse", sessionID: sessionID),
        ]
    }

    // MARK: Tests

    /// The asserted allowlist must exactly match the closed switch's universe.
    /// If the enum gains a case, the switch forces a new arm + sample value;
    /// this test then fails until `expectedCaseNames` is updated, keeping the
    /// documented contract honest.
    func test_caseNameSurfaceMatchesAssertedAllowlist() {
        let observed = Set(sampleEvents().map(caseName(for:)))
        XCTAssertEqual(
            observed, Self.expectedCaseNames,
            "ConversationEvent case surface drifted from the asserted allowlist. " +
            "If you added a text-path case, add it to expectedCaseNames AND the sample list. " +
            "If you added a run-level case, move it to RunEvent (invariant 6)."
        )
    }

    /// No ``ConversationEvent`` case name may be run/step-lifecycle-shaped —
    /// that vocabulary is reserved for ``RunEvent``.
    func test_noRunLevelShapedCaseNames() {
        let violations = Self.reservedPrefixViolations(caseNames: Self.expectedCaseNames)
        XCTAssertTrue(
            violations.isEmpty,
            "ConversationEvent cases \(violations) use a reserved run-level prefix. " +
            "Run-lifecycle events ride RunEvent, not the text path (invariant 6)."
        )
    }

    /// The mirror ``ConversationEventKind`` must enumerate the same surface as
    /// the closed switch — they are two views of one contract and must not drift.
    func test_kindMirrorMatchesClosedSwitchSurface() {
        let switchSurface = Set(sampleEvents().map(caseName(for:)))
        let kindSurface = Set(ConversationEventKind.allCases.map(\.rawValue))
        XCTAssertEqual(
            switchSurface, kindSurface,
            "ConversationEvent and its ConversationEventKind mirror have drifted apart."
        )
    }

    // MARK: - Sabotage (exercises the same `reservedPrefixViolations(caseNames:)` the audit runs)

    func test_sabotage_detectsReservedPrefixViolations() {
        let violations = Self.reservedPrefixViolations(caseNames: ["runStarted"])
        XCTAssertEqual(violations, ["runStarted"], "The planted run-level case name must be flagged")

        let clean = Self.reservedPrefixViolations(caseNames: ["messageInserted", "tokenEmitted"])
        XCTAssertTrue(clean.isEmpty, "Clean case names must not be flagged")
    }

    // MARK: - Detection

    static func reservedPrefixViolations(caseNames: Set<String>) -> [String] {
        caseNames.filter { name in reservedRunPrefixes.contains { name.hasPrefix($0) } }
    }
}
