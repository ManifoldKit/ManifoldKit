import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ArchitectEventEntry

/// A single event captured from the conversation runtime's event tap.
///
/// Stores the raw event alongside derived display properties so views can render
/// rows without re-switching on the event each frame.
public struct ArchitectEventEntry: Identifiable, Sendable {

    public let id: UUID
    /// Monotonically-increasing index within the current recording session.
    public let index: Int
    /// The kind discriminant, matching ``ConversationEventKind``.
    public let kind: ConversationEventKind
    /// Short human-readable summary of the event's key associated values.
    public let summary: String
    /// The underlying event, retained for per-entry detail views (e.g. slot inspector).
    public let event: ConversationEvent
    /// True for `.compressionTriggered` and `.historyCompressed`.
    public let isCompressionRelated: Bool
    /// True for `.errorRaised`.
    public let isError: Bool

    public init(event: ConversationEvent, index: Int) {
        self.id = UUID()
        self.index = index
        self.kind = event.kind
        self.event = event
        self.isCompressionRelated = {
            switch event {
            case .compressionTriggered, .historyCompressed:
                return true
            default:
                return false
            }
        }()
        self.isError = {
            if case .errorRaised = event { return true }
            return false
        }()
        self.summary = ArchitectEventEntry.makeSummary(for: event)
    }

    // MARK: - Summary Derivation

    private static func makeSummary(for event: ConversationEvent) -> String {
        switch event {
        case .tokenEmitted(_, let delta):
            let truncated = delta.prefix(40)
            return "\"\(truncated)\(delta.count > 40 ? "…" : "")\""

        case .streamFinished(_, let reason):
            switch reason {
            case .stop:      return "stop"
            case .cancelled: return "cancelled"
            case .empty:     return "empty"
            case .length:    return "length"
            }

        case .errorRaised(let error):
            let description = error.localizedDescription
            let truncated = description.prefix(80)
            return "\(truncated)\(description.count > 80 ? "…" : "")"

        case .contextAssembled(let slots):
            return "slots:\(slots.count)"

        case .compressionTriggered(let removed, let reason):
            let reasonStr: String = {
                switch reason {
                case .contextWindowExceeded: return "contextWindowExceeded"
                case .manual:               return "manual"
                }
            }()
            return "removed:\(removed.count) reason:\(reasonStr)"

        case .historyCompressed(_, let insertedRecords):
            return "inserted:\(insertedRecords.count)"

        case .toolCallRequested(let call):
            return call.toolName

        case .toolCallApproved(let callID):
            return callID

        case .toolCallCompleted(let callID, _):
            return callID

        case .streamStarted(let messageID):
            return messageID.uuidString.prefix(8).description

        case .messageInserted(let record):
            return record.role.rawValue

        case .messageRemoved(let messageID):
            return messageID.uuidString.prefix(8).description

        case .messageUpdated(let record):
            return record.role.rawValue

        case .sessionBranched(let newSessionID, let count):
            return "new:\(newSessionID.uuidString.prefix(8)) copied:\(count)"

        case .tokenUsageRecorded(_, let prompt, let completion):
            return "prompt:\(prompt) completion:\(completion)"

        case .thinkingStarted:
            return ""

        case .thinkingUpdated:
            return ""

        case .thinkingFinalized:
            return ""

        case .loopDetected:
            return "loop"

        case .sessionTouchFailed(let sessionID):
            return sessionID.uuidString.prefix(8).description

        case .beforeContextAssembly(let prompt, _):
            if let prompt {
                let truncated = prompt.prefix(40)
                return "\"\(truncated)\(prompt.count > 40 ? "…" : "")\""
            }
            return "(no prompt)"

        case .historyShaped(_, let diagnostics):
            return "diagnostics:\(diagnostics.count)"

        case .afterGeneration(_, let finalText):
            if finalText.isEmpty { return "(empty)" }
            let truncated = finalText.prefix(40)
            return "\"\(truncated)\(finalText.count > 40 ? "…" : "")\""

        case .agentHandoff(let from, let to):
            let fromStr = from.map { $0.uuidString.prefix(8).description } ?? "nil"
            return "from:\(fromStr) to:\(to.uuidString.prefix(8))"

        case .skillInvoked(let name, _):
            return name

        case .hookFired(let hookEvent, _):
            return hookEvent
        }
    }
}

// MARK: - ArchitectViewModel

/// Observable model backing ``ArchitectView``.
///
/// Installs an event tap on the supplied ``ConversationRuntime`` and drains
/// it into `eventLog`, bounded to the most recent 500 entries. Recording
/// begins automatically on tap installation and can be paused / restarted
/// via ``startRecording()`` and ``stopRecording()``.
@Observable
@MainActor
public final class ArchitectViewModel {

    // MARK: Public state

    /// Live event log bounded to the last 500 entries.
    public private(set) var eventLog: [ArchitectEventEntry] = []
    /// Whether the tap task is currently draining events.
    public private(set) var isRecording: Bool = false

    /// Compression-related events extracted for the context inspector.
    public var compressionEvents: [ArchitectEventEntry] {
        eventLog.filter { $0.isCompressionRelated }
    }

    /// The most recent `.contextAssembled` event.
    public var latestContextEvent: ArchitectEventEntry? {
        eventLog.last { $0.kind == .contextAssembled }
    }

    // MARK: Private

    private let runtime: ConversationRuntime
    @ObservationIgnored private var tapTask: Task<Void, Never>?

    private static let maxLogSize = 500

    // MARK: Init

    public init(runtime: ConversationRuntime) {
        self.runtime = runtime
    }

    // MARK: Recording control

    /// Installs an event tap and begins draining events into ``eventLog``.
    ///
    /// Safe to call while already recording — the second call is a no-op.
    public func startRecording() {
        guard tapTask == nil else { return }
        isRecording = true
        let tap = runtime.addEventTap(bufferingPolicy: .bufferingOldest(Self.maxLogSize))
        tapTask = Task { [weak self] in
            var idx = await self?.eventLog.count ?? 0
            for await event in tap {
                guard let self else { break }
                let entry = ArchitectEventEntry(event: event, index: idx)
                if self.eventLog.count >= Self.maxLogSize {
                    self.eventLog.removeFirst()
                }
                self.eventLog.append(entry)
                idx += 1
            }
            self?.isRecording = false
        }
    }

    /// Cancels the active tap task and stops recording.
    public func stopRecording() {
        tapTask?.cancel()
        tapTask = nil
        isRecording = false
    }

    /// Removes all captured entries from the log.
    public func clearLog() {
        eventLog.removeAll()
    }

    deinit {
        tapTask?.cancel()
    }
}
