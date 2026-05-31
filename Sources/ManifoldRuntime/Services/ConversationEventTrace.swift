import Foundation

// MARK: - ConversationEventTrace

/// A recorded sequence of ``ConversationEvent`` values with a JSONL write path.
///
/// Build a trace from a ``ConversationEventRecorder`` after its drain task
/// has completed, then call ``save(to:)`` to persist the JSONL file for
/// offline debugging or golden-trace comparison (P3).
///
/// ```swift,no-build
/// let recorder = ConversationEventRecorder()
/// let drainTask = await recorder.start(on: runtime)
///
/// let turn = try await runtime.processTurnWithOutcome(input)
/// await turn?.outcome
/// drainTask.cancel()
/// await drainTask.value
///
/// let trace = await ConversationEventTrace(recorder: recorder)
/// let url = URL(fileURLWithPath: "/tmp/turn.jsonl")
/// try trace.save(to: url)
/// ```
public struct ConversationEventTrace: Sendable {

    /// The events in delivery order.
    public let events: [ConversationEvent]

    public init(events: [ConversationEvent]) {
        self.events = events
    }

    /// Builds a trace from a ``ConversationEventRecorder`` after its drain
    /// task has completed.
    public init(recorder: ConversationEventRecorder) async {
        self.events = await recorder.trace
    }

    /// The kinds of events in delivery order — useful for quick subsequence checks.
    public var kinds: [ConversationEventKind] {
        events.map(\.kind)
    }

    /// Writes the trace as JSONL to `url`. Each line is a JSON object with
    /// `index`, `kind`, and `summary` fields.
    ///
    /// - Throws: `CocoaError` if the file cannot be written.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var lines: [String] = []
        for (i, event) in events.enumerated() {
            let entry = ConversationEventTraceEntry(
                index: i,
                kind: event.kind,
                summary: event.traceSummary
            )
            let data = try encoder.encode(entry)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - ConversationEventTraceEntry

/// One line of a JSONL trace file.
///
/// Internal implementation detail of the JSONL format — not part of the
/// public API surface.
struct ConversationEventTraceEntry: Encodable, Sendable {
    let index: Int
    let kind: ConversationEventKind
    let summary: String
}

// MARK: - traceSummary

private extension ConversationEvent {

    /// A human-readable one-liner derived from the event, used as the
    /// `summary` field in JSONL trace entries.
    var traceSummary: String {
        switch self {
        case let .tokenEmitted(_, delta):
            // Truncate long deltas so traces remain human-readable.
            return String(delta.prefix(40))

        case let .streamFinished(_, reason):
            return "\(reason)"

        case let .errorRaised(error):
            // Truncate to keep individual trace lines reasonable.
            return String(error.localizedDescription.prefix(80))

        case let .contextAssembled(slots):
            return "slots:\(slots.count)"

        case let .compressionTriggered(_, reason):
            return "\(reason)"

        case let .historyCompressed(_, insertedRecords):
            return "inserted:\(insertedRecords.count)"

        case let .toolCallRequested(toolCall):
            return toolCall.toolName

        case let .toolCallCompleted(callID, _):
            return callID

        default:
            return ""
        }
    }
}
