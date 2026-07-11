import ManifoldInference
import ManifoldRuntime

/// Everything a checkpoint scorer needs, bundled once per checkpoint
/// evaluation: the ``EvalScorer``-shaped output projection, the state
/// snapshot from an optional ``ScenarioStateProbe``, and the checkpoint
/// declaration itself (so a scorer can read its own `custom` payload).
///
/// Built on ``EvalRunOutput`` — no fourth scorer protocol, no parallel
/// `EvalScore` type (design v1 §3, "no fourth scorer protocol"). `output` is a
/// projection of everything produced *up to and including* the checkpoint's
/// `afterTurnIndex`, not just the final turn.
///
/// The four `last*`/`eventKinds`/`producedMessageCount` fields carry
/// turn-loop-structural data ``EvalRunOutput`` deliberately does not (and
/// must not — `ManifoldInference`, where `EvalRunOutput` lives, has no
/// dependency on `ManifoldRuntime`'s `ConversationEventKind`/`PromptSlot`
/// types). They exist so the built-in `expectedEvents` / `expectedCompression`
/// / `expectedContextSlots` scorers have something to read without inventing
/// a parallel output type.
public struct CheckpointEvaluationContext: Sendable {
    /// The id of the ``GoldenTaskFixture`` being evaluated, supplied by
    /// ``GoldenTaskRunner`` — so scorers that need a stable per-fixture
    /// identity (e.g. ``JudgedCheckpointScorer``'s diagnostic request ids)
    /// read it from the run itself rather than trusting a constructor
    /// parameter that could silently drift from the fixture actually running.
    /// Empty only for hand-built contexts (unit tests) that don't set it.
    public let fixtureID: String
    /// Read-only projection of the run's output up to this checkpoint.
    public let output: EvalRunOutput
    /// The app-supplied state snapshot, or `nil` when no ``ScenarioStateProbe``
    /// was registered (or the probe declined to snapshot this checkpoint).
    public let snapshot: (any Sendable)?
    /// The checkpoint being evaluated.
    public let checkpoint: GoldenCheckpoint
    /// The event trace's kinds, in order, up to and including this
    /// checkpoint's turn.
    public let eventKinds: [ConversationEventKind]
    /// Message count in the store as of this checkpoint.
    public let producedMessageCount: Int
    /// `slots.count` of the most recent `contextAssembled` event up to this
    /// checkpoint, or `nil` if none fired yet.
    public let lastContextAssembledSlotCount: Int?
    /// `insertedRecords.count` of the most recent `historyCompressed` event up
    /// to this checkpoint, or `nil` if compression hasn't fired yet.
    public let lastCompressionInsertedRecordCount: Int?
    /// Assistant text produced by this checkpoint's own turn only —
    /// everything after the most recent user message — as opposed to
    /// ``output``'s `visibleText`, which is the full cumulative transcript up
    /// to this checkpoint. Feeds
    /// ``BuiltInCheckpointScorers/ContentMatchOptions/Scope/latestTurn``.
    /// Empty for hand-built contexts (unit tests) that don't set it.
    public let latestTurnVisibleText: String

    public init(
        output: EvalRunOutput,
        snapshot: (any Sendable)?,
        checkpoint: GoldenCheckpoint,
        eventKinds: [ConversationEventKind],
        producedMessageCount: Int,
        lastContextAssembledSlotCount: Int?,
        lastCompressionInsertedRecordCount: Int?,
        fixtureID: String = "",
        latestTurnVisibleText: String = ""
    ) {
        self.fixtureID = fixtureID
        self.output = output
        self.snapshot = snapshot
        self.checkpoint = checkpoint
        self.eventKinds = eventKinds
        self.producedMessageCount = producedMessageCount
        self.lastContextAssembledSlotCount = lastContextAssembledSlotCount
        self.lastCompressionInsertedRecordCount = lastCompressionInsertedRecordCount
        self.latestTurnVisibleText = latestTurnVisibleText
    }
}

/// Scores one named assertion against a ``CheckpointEvaluationContext``,
/// registered by id and dispatched from a checkpoint's ``GoldenCheckpoint/custom``
/// payloads.
///
/// App-registered conformances read `context.checkpoint.custom[scorer's own
/// id]` for their opaque payload; the harness never interprets `custom` on
/// their behalf. Built-in scorers for the schema's own assertion kinds
/// (`requiredContent`, `expectedEvents`, …) are plain functions in
/// ``BuiltInCheckpointScorers``, not `CheckpointScorer` conformances — they
/// read fixed fields, not a `custom` payload, so the id-dispatch seam doesn't
/// apply to them.
public protocol CheckpointScorer: Sendable {
    /// The key this scorer answers for — matched against
    /// ``GoldenCheckpoint/custom`` keys.
    var id: String { get }

    func score(_ context: CheckpointEvaluationContext) async -> EvalScore
}
