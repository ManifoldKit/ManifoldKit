import Foundation

// MARK: - GoldenTaskFixture

/// The declarative, on-disk shape of one golden scenario: a system prompt, a
/// turn sequence, and a set of checkpoints that assert against the trace and
/// produced state at specific points in the conversation.
///
/// This is the "portable 80%" the design (appeval-design-v2 §3.2) describes:
/// turns + the common checkpoint assertion shapes cover most app goldens
/// without any Swift code. Anything the schema can't express is reached by
/// asserting directly on ``RuntimeScenarioRunner/Result/trace`` in Swift — the
/// documented escape hatch (see the module's DocC page).
public struct GoldenTaskFixture: Codable, Sendable, Equatable {
    /// Stable identifier — used as the ledger key and report row label.
    public let id: String

    /// Optional system prompt for every turn in this fixture, plumbed through
    /// ``RuntimeScenario/systemPrompt``.
    public let systemPrompt: String?

    /// The turn sequence, in order.
    public let turns: [GoldenTurn]

    /// Assertions evaluated at specific points in the turn sequence.
    public let checkpoints: [GoldenCheckpoint]

    public init(
        id: String,
        systemPrompt: String? = nil,
        turns: [GoldenTurn],
        checkpoints: [GoldenCheckpoint]
    ) {
        self.id = id
        self.systemPrompt = systemPrompt
        self.turns = turns
        self.checkpoints = checkpoints
    }
}

// MARK: - GoldenTurn

/// One turn in a ``GoldenTaskFixture``'s turn sequence.
public struct GoldenTurn: Codable, Sendable, Equatable {
    /// The user action this turn performs.
    ///
    /// `.edit` is declared for forward-compatibility only: the runner's
    /// turn-kind enum has no edit case yet (an edit needs a runtime-assigned
    /// `messageID` a JSON fixture cannot know ahead of time), so
    /// ``GoldenTaskMapper/map(_:)`` **throws**
    /// `MapError.editNotYetSupported(turnIndex:)` for any fixture that uses
    /// it — see the mapper's doc comment for the full rationale.
    public enum Kind: String, Codable, Sendable {
        case send
        case regenerate
        case edit
    }

    public let kind: Kind

    /// The user message text. Required for `.send`; required for `.edit`
    /// (the replacement text); ignored for `.regenerate`.
    public let text: String?

    /// The scripted assistant reply for this turn, played back verbatim by
    /// the deterministic lane's ``ScriptedGenerationBackend``. `nil` produces
    /// an empty turn (stream finishes with no visible tokens) — rare, but
    /// valid for asserting error/edge-case paths.
    ///
    /// When ``scriptedToolCall`` is also set, this is the *follow-up* answer
    /// the model gives after the tool result is fed back (round 2 of the tool
    /// round trip).
    public let cannedResponse: String?

    /// When non-nil, the runner cancels this turn's stream after observing
    /// this many tokens — see ``RuntimeScenario/ScenarioTurn/cancelAfterTokens``.
    public let cancelAfterTokens: Int?

    /// When non-nil, the scripted model requests this tool call *before*
    /// producing ``cannedResponse`` — one full tool round trip driven from a
    /// single user turn, scripted exactly the way MK's own tool-round-trip
    /// scenario scripts it (a `.toolCall` backend round, then the follow-up
    /// answer round).
    public let scriptedToolCall: GoldenScriptedToolCall?

    public init(
        kind: Kind,
        text: String? = nil,
        cannedResponse: String? = nil,
        cancelAfterTokens: Int? = nil,
        scriptedToolCall: GoldenScriptedToolCall? = nil
    ) {
        self.kind = kind
        self.text = text
        self.cannedResponse = cannedResponse
        self.cancelAfterTokens = cancelAfterTokens
        self.scriptedToolCall = scriptedToolCall
    }
}

// MARK: - GoldenScriptedToolCall

/// A tool call the scripted model emits during a ``GoldenTurn``.
///
/// This is what makes ``GoldenCheckpoint/expectedToolCalls`` satisfiable from
/// the JSON path alone: the fixture scripts the call the "model" makes, and
/// the checkpoint asserts it was routed through the runtime's dispatch loop.
public struct GoldenScriptedToolCall: Codable, Sendable, Equatable {
    /// The tool name the scripted model requests.
    public let name: String

    /// JSON-encoded arguments string the scripted model emits with the call.
    /// Defaults to `"{}"` when absent.
    public let arguments: String?

    /// The tool's scripted result payload. When non-nil the mapper registers
    /// a synthetic fixed-response executor for ``name`` automatically, so the
    /// JSON fixture is self-sufficient. When `nil` the caller must supply a
    /// matching executor via `GoldenTaskRunner.run(toolExecutors:)` — for
    /// apps that want their *real* executor exercised.
    public let result: String?

    public init(name: String, arguments: String? = nil, result: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.result = result
    }
}

// MARK: - GoldenCheckpoint

/// An assertion point in a ``GoldenTaskFixture``'s turn sequence.
///
/// Every field beyond `afterTurnIndex` is optional — a checkpoint only
/// evaluates the assertion kinds it declares. Missing an assertion kind is
/// not scored at all (there is no implicit "everything else must be absent"
/// rule); an assertion kind whose fixture-declared shape can't be evaluated
/// (e.g. no prober registered for `custom`) scores `.unavailable`, never a
/// silent pass or a zero.
public struct GoldenCheckpoint: Codable, Sendable, Equatable {
    /// 0-based index into the fixture's `turns` array. The checkpoint
    /// evaluates state as of the *end* of this turn (inclusive).
    public let afterTurnIndex: Int

    /// Human-readable label for report rows. Defaults to `"turn \(afterTurnIndex)"`
    /// when absent.
    public let label: String?

    /// Substrings that must all appear in the assistant's visible text
    /// produced up to and including this checkpoint's turn.
    public let requiredContent: [String]?

    /// Substrings that must NOT appear in the assistant's visible text
    /// produced up to and including this checkpoint's turn.
    public let forbiddenContent: [String]?

    /// ``ConversationEventKind`` raw values that must appear, in order, as a
    /// subsequence of the trace up to and including this checkpoint's turn.
    public let expectedEvents: [String]?

    /// Tool calls that must appear (by name, with argument substring checks)
    /// up to and including this checkpoint's turn.
    public let expectedToolCalls: [GoldenExpectedToolCall]?

    /// Payload-aware compression assertion — the count of messages retained
    /// and/or the count of records a compression pass inserted.
    public let expectedCompression: GoldenExpectedCompression?

    /// Payload-aware context-assembly assertion — the number of prompt slots
    /// assembled for this checkpoint's turn.
    public let expectedContextSlots: GoldenExpectedContextSlots?

    /// Opaque payloads routed to app-registered ``CheckpointScorer``
    /// conformances by id. The harness never interprets these — the payload
    /// is handed to the scorer verbatim.
    public let custom: [String: JSONValue]?

    public init(
        afterTurnIndex: Int,
        label: String? = nil,
        requiredContent: [String]? = nil,
        forbiddenContent: [String]? = nil,
        expectedEvents: [String]? = nil,
        expectedToolCalls: [GoldenExpectedToolCall]? = nil,
        expectedCompression: GoldenExpectedCompression? = nil,
        expectedContextSlots: GoldenExpectedContextSlots? = nil,
        custom: [String: JSONValue]? = nil
    ) {
        self.afterTurnIndex = afterTurnIndex
        self.label = label
        self.requiredContent = requiredContent
        self.forbiddenContent = forbiddenContent
        self.expectedEvents = expectedEvents
        self.expectedToolCalls = expectedToolCalls
        self.expectedCompression = expectedCompression
        self.expectedContextSlots = expectedContextSlots
        self.custom = custom
    }

    /// The report/diagnostic label — the declared ``label`` or a stable
    /// fallback derived from ``afterTurnIndex``.
    public var displayLabel: String {
        label ?? "turn \(afterTurnIndex)"
    }
}

// MARK: - GoldenExpectedToolCall

public struct GoldenExpectedToolCall: Codable, Sendable, Equatable {
    /// The tool name that must have been called (``ToolCall/toolName``).
    public let name: String

    /// Expected substrings within the JSON-decoded argument values, keyed by
    /// argument name. A key present here that is absent from the actual call's
    /// decoded arguments (or whose stringified value doesn't contain the
    /// expected substring) fails the assertion.
    public let argumentsContain: [String: String]?

    public init(name: String, argumentsContain: [String: String]? = nil) {
        self.name = name
        self.argumentsContain = argumentsContain
    }
}

// MARK: - GoldenExpectedCompression

public struct GoldenExpectedCompression: Codable, Sendable, Equatable {
    /// Upper bound on the number of messages retained in the store as of this
    /// checkpoint (proves compression actually shrank history).
    public let maxRetainedMessages: Int?

    /// Lower bound on the number of records the most recent
    /// `historyCompressed` event inserted.
    public let minInsertedRecords: Int?

    public init(maxRetainedMessages: Int? = nil, minInsertedRecords: Int? = nil) {
        self.maxRetainedMessages = maxRetainedMessages
        self.minInsertedRecords = minInsertedRecords
    }
}

// MARK: - GoldenExpectedContextSlots

public struct GoldenExpectedContextSlots: Codable, Sendable, Equatable {
    /// Lower bound on the number of ``PromptSlot`` values assembled for this
    /// checkpoint's turn (the most recent `contextAssembled` event).
    public let minSlots: Int?

    /// Upper bound on the same count.
    public let maxSlots: Int?

    public init(minSlots: Int? = nil, maxSlots: Int? = nil) {
        self.minSlots = minSlots
        self.maxSlots = maxSlots
    }
}
