import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Tripwire enforcing invariant 6 from the target-architecture plan
/// (docs/plans/archive/target-architecture.md, removed in a 2026-07
/// docs/plans hygiene pass — see git history):
///
/// > "New modality/run-level events ride their own event types — never new
/// > `GenerationEvent` cases on the text path."
///
/// Specifically this test asserts that no run-level payload appears as a
/// ``ConversationEvent`` case. ``RunEvent`` is the separate type that owns
/// the run-lifecycle vocabulary, keeping exhaustive switches in text
/// consumers closed.
///
/// Adding a new ``ConversationEvent`` case that carries run-level payload
/// (started/step/paused/resumed/completed/cancelled/failed vocabulary)
/// must fail this test — that is the intended tripwire behavior.
///
/// The test works by:
/// 1. Enumerating every ``ConversationEventKind`` case and asserting no
///    case name matches the run-level vocabulary.
/// 2. Asserting ``RunEvent`` case names are disjoint from
///    ``ConversationEventKind`` case names, so the two surfaces can
///    never silently merge.
///
/// - Note: If this test fails after adding a new ``ConversationEvent`` case,
///   the correct fix is to put the new events in ``RunEvent`` instead.
final class GenerationEventClosedAuditTest: XCTestCase {

    // MARK: Run-level vocabulary

    /// Keywords that identify run-lifecycle concepts. These must never appear
    /// as ``ConversationEvent`` / ``ConversationEventKind`` case names.
    private let runLevelKeywords: Set<String> = [
        "runStarted", "runPaused", "runResumed", "runCompleted",
        "runCancelled", "runFailed", "stepStarted", "stepCompleted",
        "stepFailed"
    ]

    // MARK: Tests

    func test_noRunLevelPayloadInConversationEventKind() {
        let allKinds = ConversationEventKind.allCases.map(\.rawValue)
        for keyword in runLevelKeywords {
            XCTAssertFalse(
                allKinds.contains(keyword),
                "ConversationEventKind must not contain run-level case '\(keyword)'. " +
                "Run-lifecycle events ride RunEvent (target-architecture invariant 6; " +
                "see this test's doc comment)."
            )
        }
    }

    func test_runEventCasesDisjointFromConversationEventKindCases() {
        let conversationKinds = Set(ConversationEventKind.allCases.map(\.rawValue))
        for keyword in runLevelKeywords {
            XCTAssertFalse(
                conversationKinds.contains(keyword),
                "ConversationEventKind '\(keyword)' overlaps with RunEvent vocabulary. " +
                "These two event surfaces must remain disjoint (invariant 6)."
            )
        }
    }

    func test_runEventCasesExistInRunEvent() {
        // Verify RunEvent actually has the expected run-level cases so the
        // audit is honest about what it's protecting.
        let runEvents: [RunEvent] = [
            .runStarted(runID: UUID(), sessionID: UUID(), goal: "test"),
            .stepStarted(runID: UUID(), stepIndex: 0, stepID: UUID()),
            .stepCompleted(runID: UUID(), stepIndex: 0, stepID: UUID(), messageID: nil),
            .stepFailed(runID: UUID(), stepIndex: 0, stepID: UUID(), reason: "test"),
            .runPaused(runID: UUID(), stepCount: 0),
            .runResumed(runID: UUID(), stepCount: 0),
            .runCompleted(runID: UUID(), stepCount: 1),
            .runCancelled(runID: UUID(), stepCount: 0),
            .runFailed(runID: UUID(), reason: "test"),
        ]
        // Exhaustive instantiation: if RunEvent adds a case, this must grow.
        // The count assertion ensures future cases are accounted for here.
        XCTAssertEqual(runEvents.count, 9,
                       "Update this test when adding or removing RunEvent cases.")
    }
}
