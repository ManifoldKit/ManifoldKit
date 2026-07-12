import Foundation

// MARK: - GenerationEventTrace

/// A recorded sequence of ``GenerationEvent`` values with a JSONL write path.
///
/// Direct-`InferenceService` counterpart to `ManifoldRuntime`'s
/// `ConversationEventTrace` (#2206) — same on-disk shape (`index` / `kind` /
/// `summary` per line), one layer down. Build a trace from a
/// ``GenerationEventRecorder`` after its drain task has completed, then call
/// ``save(to:)`` to persist the JSONL file for offline debugging or
/// golden-trace comparison.
///
/// ```swift,no-build
/// let recorder = GenerationEventRecorder()
/// let drainTask = await recorder.start(on: service)
///
/// let (_, stream) = try service.enqueue(messages: [.user("hi")], config: GenerationConfig())
/// for try await _ in stream.events {}
/// drainTask.cancel()
/// await drainTask.value
///
/// let trace = await GenerationEventTrace(recorder: recorder)
/// let url = URL(fileURLWithPath: "/tmp/generation.jsonl")
/// try trace.save(to: url)
/// ```
public struct GenerationEventTrace: Sendable {

    /// The events in delivery order.
    public let events: [GenerationEvent]

    public init(events: [GenerationEvent]) {
        self.events = events
    }

    /// Builds a trace from a ``GenerationEventRecorder`` after its drain
    /// task has completed.
    public init(recorder: GenerationEventRecorder) async {
        self.events = await recorder.trace
    }

    /// The kinds of events in delivery order — useful for quick subsequence checks.
    public var kinds: [GenerationEventKind] {
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
            let entry = GenerationEventTraceEntry(
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

// MARK: - GenerationEventTraceEntry

/// One line of a JSONL trace file.
///
/// Internal implementation detail of the JSONL format — not part of the
/// public API surface.
struct GenerationEventTraceEntry: Encodable, Sendable {
    let index: Int
    let kind: GenerationEventKind
    let summary: String
}

// MARK: - traceSummary

private extension GenerationEvent {

    /// A human-readable one-liner derived from the event, used as the
    /// `summary` field in JSONL trace entries.
    var traceSummary: String {
        switch self {
        case let .promptRendered(text):
            return "chars:\(text.count)"

        case let .token(text):
            // Truncate long deltas so traces remain human-readable.
            return String(text.prefix(40))

        case let .toolCall(call):
            return call.toolName

        case let .toolCallStart(_, name):
            return name

        case let .toolResult(result):
            return result.callId

        case let .toolDispatchStarted(_, name, attempt):
            return "\(name) attempt:\(attempt)"

        case let .toolDispatchCompleted(callId, durationMilliseconds, errorKind):
            return errorKind.map { "\(callId) \($0) \(durationMilliseconds)ms" }
                ?? "\(callId) ok \(durationMilliseconds)ms"

        case let .generationCompleted(completion):
            return "\(completion.reason)"

        case let .toolIterationLimitExceeded(iterations):
            return "iterations:\(iterations)"

        case let .kvCacheReuse(promptTokensReused):
            return "reused:\(promptTokensReused)"

        default:
            return ""
        }
    }
}
