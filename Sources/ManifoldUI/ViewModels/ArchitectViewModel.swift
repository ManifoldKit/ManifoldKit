import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ArchitectEventCategory

/// High-level grouping used to colour-code rows in the Architect timeline.
///
/// Decouples the view's colour mapping from the underlying event enums so the
/// timeline can render conversation, image-generation, and video-generation
/// events side by side. Conversation events derive their category from
/// ``ConversationEventKind``; image/video events map to the dedicated
/// ``imageGeneration`` / ``videoGeneration`` cases.
public enum ArchitectEventCategory: Sendable, Equatable {
    case streaming
    case context
    case compression
    case error
    case tool
    case agent
    case thinking
    case message
    case imageGeneration
    case videoGeneration

    /// Maps a ``ConversationEventKind`` to its display category.
    static func from(_ kind: ConversationEventKind) -> ArchitectEventCategory {
        switch kind {
        case .streamStarted, .streamFinished, .tokenEmitted:
            return .streaming
        case .contextAssembled, .beforeContextAssembly, .historyShaped:
            return .context
        case .compressionTriggered, .historyCompressed:
            return .compression
        case .errorRaised:
            return .error
        case .toolCallRequested, .toolCallApproved, .toolCallCompleted:
            return .tool
        case .agentHandoff, .skillInvoked, .hookFired:
            return .agent
        case .thinkingStarted, .thinkingUpdated, .thinkingFinalized:
            return .thinking
        case .messageInserted, .messageRemoved, .messageUpdated,
             .sessionBranched, .tokenUsageRecorded, .loopDetected,
             .sessionTouchFailed, .afterGeneration:
            return .message
        }
    }
}

// MARK: - ArchitectEventEntry

/// A single event captured from a runtime's event tap.
///
/// Stores derived display properties so views can render rows without
/// re-switching on the event each frame. The entry is source-agnostic — it can
/// represent a ``ConversationEvent``, an ``ImageRuntimeEvent``, or a
/// ``VideoRuntimeEvent``. Conversation entries retain ``kind`` and ``event`` for
/// the per-entry detail views (slot inspector); image/video entries leave those
/// `nil` and are identified by ``category``.
public struct ArchitectEventEntry: Identifiable, Sendable {

    public let id: UUID
    /// Monotonically-increasing index within the current recording session.
    public let index: Int
    /// Human-readable event name shown as the row's primary label.
    public let label: String
    /// Display category driving the row's colour coding.
    public let category: ArchitectEventCategory
    /// Short human-readable summary of the event's key associated values.
    public let summary: String
    /// The conversation event kind, or `nil` for image/video entries.
    public let kind: ConversationEventKind?
    /// The underlying conversation event, retained for per-entry detail views
    /// (e.g. slot inspector). `nil` for image/video entries.
    public let event: ConversationEvent?
    /// True for `.compressionTriggered` and `.historyCompressed`.
    public let isCompressionRelated: Bool
    /// True for any failure event (`.errorRaised`, image/video `.failed`).
    public let isError: Bool

    // MARK: Conversation init

    public init(event: ConversationEvent, index: Int) {
        self.id = UUID()
        self.index = index
        self.kind = event.kind
        self.label = event.kind.rawValue
        self.category = ArchitectEventCategory.from(event.kind)
        self.event = event
        self.isCompressionRelated = {
            if case .compressionTriggered = event { return true }
            if case .historyCompressed = event { return true }
            return false
        }()
        self.isError = {
            if case .errorRaised = event { return true }
            return false
        }()
        self.summary = ArchitectEventEntry.makeSummary(for: event)
    }

    // MARK: Image init

    public init(imageEvent: ImageRuntimeEvent, index: Int) {
        self.id = UUID()
        self.index = index
        self.kind = nil
        self.event = nil
        self.category = .imageGeneration
        self.isCompressionRelated = false
        switch imageEvent {
        case .started(_, let prompt):
            self.label = "image.started"
            let truncated = prompt.prefix(40)
            self.summary = "\"\(truncated)\(prompt.count > 40 ? "…" : "")\""
            self.isError = false
        case .progress(_, let step, let totalSteps):
            self.label = "image.progress"
            self.summary = "step:\(step)/\(totalSteps)"
            self.isError = false
        case .preview(_, let step, let totalSteps, let image):
            self.label = "image.preview"
            self.summary = "step:\(step)/\(totalSteps) (\(image.count) bytes)"
            self.isError = false
        case .completed(_, let payload):
            self.label = "image.completed"
            self.summary = payload.modelIdentifier ?? "completed"
            self.isError = false
        case .failed(_, let error):
            self.label = "image.failed"
            let description = error.localizedDescription
            let truncated = description.prefix(80)
            self.summary = "\(truncated)\(description.count > 80 ? "…" : "")"
            self.isError = true
        case .cancelled:
            self.label = "image.cancelled"
            self.summary = "cancelled"
            self.isError = false
        }
    }

    // MARK: Video init

    public init(videoEvent: VideoRuntimeEvent, index: Int) {
        self.id = UUID()
        self.index = index
        self.kind = nil
        self.event = nil
        self.category = .videoGeneration
        self.isCompressionRelated = false
        switch videoEvent {
        case .started(_, let prompt):
            self.label = "video.started"
            let truncated = prompt.prefix(40)
            self.summary = "\"\(truncated)\(prompt.count > 40 ? "…" : "")\""
            self.isError = false
        case .progress(_, let fractionComplete):
            self.label = "video.progress"
            self.summary = String(format: "%.0f%%", fractionComplete * 100)
            self.isError = false
        case .completed(_, let payload):
            self.label = "video.completed"
            self.summary = payload.modelIdentifier
            self.isError = false
        case .failed(_, let error):
            self.label = "video.failed"
            let description = error.localizedDescription
            let truncated = description.prefix(80)
            self.summary = "\(truncated)\(description.count > 80 ? "…" : "")"
            self.isError = true
        case .cancelled:
            self.label = "video.cancelled"
            self.summary = "cancelled"
            self.isError = false
        }
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
            case .timedOut:  return "timedOut"
            @unknown default: return "unknown"
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
/// Installs an event tap on the supplied ``ConversationRuntime`` — and,
/// optionally, on an ``ImageGenerationRuntime`` and ``VideoGenerationRuntime`` —
/// and drains them into a single `eventLog`, bounded to the most recent 500
/// entries. Recording begins automatically on tap installation and can be
/// paused / restarted via ``startRecording()`` and ``stopRecording()``.
///
/// Image/video subscription is nil-safe: chat-only hosts pass no generation
/// runtimes and only conversation events appear in the timeline.
@Observable
@MainActor
public final class ArchitectViewModel {

    // MARK: Public state

    /// Live event log bounded to the last 500 entries.
    public private(set) var eventLog: [ArchitectEventEntry] = []
    /// Whether the conversation tap task is currently draining events.
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
    private let imageRuntime: ImageGenerationRuntime?
    private let videoRuntime: VideoGenerationRuntime?

    @ObservationIgnored private var tapTask: Task<Void, Never>?
    @ObservationIgnored private var imageTapTask: Task<Void, Never>?
    @ObservationIgnored private var videoTapTask: Task<Void, Never>?

    /// Shared monotonically-increasing index across all event sources so rows
    /// from different runtimes interleave with a single coherent ordering.
    @ObservationIgnored private var nextEventIndex: Int = 0

    private static let maxLogSize = 500

    // MARK: Init

    /// Creates a view model that taps the supplied runtimes.
    ///
    /// - Parameters:
    ///   - runtime: The conversation runtime whose events form the primary
    ///     timeline.
    ///   - imageRuntime: Optional image-generation runtime. When supplied, its
    ///     events fold into the same timeline. `nil` for chat-only hosts.
    ///   - videoRuntime: Optional video-generation runtime. When supplied, its
    ///     events fold into the same timeline. `nil` for chat-only hosts.
    public init(
        runtime: ConversationRuntime,
        imageRuntime: ImageGenerationRuntime? = nil,
        videoRuntime: VideoGenerationRuntime? = nil
    ) {
        self.runtime = runtime
        self.imageRuntime = imageRuntime
        self.videoRuntime = videoRuntime
    }

    // MARK: Recording control

    /// Installs event taps and begins draining events into ``eventLog``.
    ///
    /// Safe to call while already recording — the second call is a no-op.
    public func startRecording() {
        guard tapTask == nil else { return }
        isRecording = true
        nextEventIndex = eventLog.count

        let tap = runtime.addEventTap(bufferingPolicy: .bufferingOldest(Self.maxLogSize))
        tapTask = Task { [weak self] in
            for await event in tap {
                guard let self else { break }
                self.append(ArchitectEventEntry(event: event, index: self.takeNextIndex()))
            }
            self?.isRecording = false
        }

        if let imageRuntime {
            let imageTap = imageRuntime.addEventTap(bufferingPolicy: .bufferingOldest(Self.maxLogSize))
            imageTapTask = Task { [weak self] in
                for await event in imageTap {
                    guard let self else { break }
                    self.append(ArchitectEventEntry(imageEvent: event, index: self.takeNextIndex()))
                }
            }
        }

        if let videoRuntime {
            let videoTap = videoRuntime.addEventTap(bufferingPolicy: .bufferingOldest(Self.maxLogSize))
            videoTapTask = Task { [weak self] in
                for await event in videoTap {
                    guard let self else { break }
                    self.append(ArchitectEventEntry(videoEvent: event, index: self.takeNextIndex()))
                }
            }
        }
    }

    /// Cancels all active tap tasks and stops recording.
    public func stopRecording() {
        tapTask?.cancel()
        tapTask = nil
        imageTapTask?.cancel()
        imageTapTask = nil
        videoTapTask?.cancel()
        videoTapTask = nil
        isRecording = false
    }

    /// Removes all captured entries from the log.
    public func clearLog() {
        eventLog.removeAll()
        nextEventIndex = 0
    }

    // MARK: Helpers

    private func takeNextIndex() -> Int {
        let idx = nextEventIndex
        nextEventIndex += 1
        return idx
    }

    private func append(_ entry: ArchitectEventEntry) {
        if eventLog.count >= Self.maxLogSize {
            eventLog.removeFirst()
        }
        eventLog.append(entry)
    }

    deinit {
        tapTask?.cancel()
        imageTapTask?.cancel()
        videoTapTask?.cancel()
    }
}
