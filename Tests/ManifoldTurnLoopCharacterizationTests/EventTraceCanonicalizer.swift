import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - EventTraceCanonicalizer

/// Produces a stable, human-readable text serialization of a
/// ``ConversationEvent`` sequence for snapshot comparison.
///
/// UUIDs are replaced by positional labels (`<uuid:N>`) in order of first
/// appearance so goldens are deterministic across runs. Timestamps and other
/// volatile values are omitted. The canonicalizer is stateful — share one
/// instance across the event and records snapshots for a single test so UUID
/// labels are consistent between the two files.
struct EventTraceCanonicalizer {

    private var uuidLabels: [UUID: String] = [:]
    private var counter = 0

    // MARK: - Public API

    /// Serializes a sequence of events to a newline-separated string.
    mutating func serialize(events: [ConversationEvent]) -> String {
        events.enumerated().map { i, e in "\(i)  \(describe(e))" }
            .joined(separator: "\n")
    }

    /// Serializes persisted ``ChatMessage`` values to a newline-separated
    /// string. Use the same instance that serialized the events so UUID labels
    /// are shared.
    mutating func serialize(records: [ChatMessage]) -> String {
        records.enumerated().map { i, r in
            let text = r.content
            let c = text.isEmpty ? "(empty)" : "\"\(text.prefix(80))\""
            let extra = r.contentParts.count > 1 ? " parts:\(r.contentParts.count)" : ""
            return "\(i)  id:\(label(r.id)) role:\(r.role.rawValue) content:\(c)\(extra)"
        }.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private mutating func label(_ uuid: UUID) -> String {
        if let l = uuidLabels[uuid] { return l }
        counter += 1
        let l = "<uuid:\(counter)>"
        uuidLabels[uuid] = l
        return l
    }

    private mutating func describe(_ event: ConversationEvent) -> String {
        switch event {
        case let .beforeContextAssembly(prompt, request):
            let p = prompt.map { "\"\($0)\"" } ?? "nil"
            return "beforeContextAssembly  session:\(label(request.sessionID)) prompt:\(p) msgCount:\(request.messageCount)"
        case let .contextAssembled(slots):
            return "contextAssembled  slots:\(slots.count)"
        case let .messageInserted(msg):
            let text = msg.content
            let c = text.isEmpty ? "(empty)" : "\"\(text.prefix(40))\""
            return "messageInserted  id:\(label(msg.id)) role:\(msg.role.rawValue) content:\(c)"
        case let .messageRemoved(id):
            return "messageRemoved  id:\(label(id))"
        case let .messageUpdated(msg):
            let text = msg.content
            let c = text.isEmpty ? "(empty)" : "\"\(text.prefix(40))\""
            return "messageUpdated  id:\(label(msg.id)) role:\(msg.role.rawValue) content:\(c)"
        case let .sessionBranched(newSessionID, copiedCount):
            return "sessionBranched  newSession:\(label(newSessionID)) copiedCount:\(copiedCount)"
        case let .streamStarted(id):
            return "streamStarted  id:\(label(id))"
        case let .tokenEmitted(id, delta):
            return "tokenEmitted  id:\(label(id)) delta:\"\(delta)\""
        case let .tokenUsageRecorded(id, prompt, completion):
            return "tokenUsageRecorded  id:\(label(id)) prompt:\(prompt) completion:\(completion)"
        case let .thinkingStarted(id):
            return "thinkingStarted  id:\(label(id))"
        case let .thinkingUpdated(id, partial):
            return "thinkingUpdated  id:\(label(id)) partial:\"\(partial.prefix(40))\""
        case let .thinkingFinalized(id, text, _):
            return "thinkingFinalized  id:\(label(id)) text:\"\(text.prefix(40))\""
        case let .loopDetected(id):
            return "loopDetected  id:\(label(id))"
        case let .streamFinished(id, reason):
            return "streamFinished  id:\(label(id)) reason:\(reason)"
        case let .errorRaised(error):
            return "errorRaised  \(String(error.localizedDescription.prefix(80)))"
        case let .sessionTouchFailed(sid):
            return "sessionTouchFailed  session:\(label(sid))"
        case let .historyShaped(sid, diagnostics):
            return "historyShaped  session:\(label(sid)) count:\(diagnostics.count)"
        case let .afterGeneration(id, finalText):
            return "afterGeneration  id:\(label(id)) finalText:\"\(finalText.prefix(80))\""
        case let .compressionTriggered(removed, reason):
            return "compressionTriggered  removed:\(removed.count) reason:\(reason)"
        case let .historyCompressed(sid, records):
            return "historyCompressed  session:\(label(sid)) inserted:\(records.count)"
        case let .toolCallRequested(call):
            return "toolCallRequested  callId:\(call.id) tool:\(call.toolName)"
        case let .toolCallApproved(callID):
            return "toolCallApproved  callId:\(callID)"
        case let .toolCallCompleted(callID, result):
            return "toolCallCompleted  callId:\(callID) status:\(result.errorKind == nil ? "ok" : "err")"
        case let .agentHandoff(from, to):
            return "agentHandoff  from:\(from.map { label($0) } ?? "nil") to:\(label(to))"
        case let .skillInvoked(name, _):
            return "skillInvoked  name:\(name)"
        case let .hookFired(event, _):
            return "hookFired  event:\(event)"
        }
    }
}
