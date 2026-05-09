import Foundation

/// Heals transcripts that contain orphan ``MessagePart/toolCall`` parts —
/// tool invocations that never received a matching ``MessagePart/toolResult``.
///
/// Cloud APIs (OpenAI, Anthropic, Ollama) reject a follow-up turn whose
/// history contains an unanswered ``ToolCall`` with `"missing tool_result for
/// tool_use id …"`. Orphans appear when a process is killed mid-tool — the
/// model emitted a tool call, the registry started executing, but the host
/// terminated before the result was persisted. On the next session reload the
/// transcript still references the call, the next user turn is sent to the
/// API, and the request bounces.
///
/// Re-dispatching the original tool is unsafe: tools have side effects (file
/// writes, HTTP POSTs, payments) and the previous attempt may have already
/// completed those. Instead we synthesise a terminal ``ToolResult`` with
/// ``ToolResult/ErrorKind/cancelled``, which lets the model acknowledge the
/// gap and decide what to do next.
///
/// The healer is a value-only type with no state — it operates on
/// ``ChatMessageRecord`` arrays (or raw ``MessagePart`` arrays for tests) and
/// returns a new array with synthesised result parts inserted directly after
/// each orphan call. Healing is idempotent: re-running it on an already-healed
/// transcript is a no-op.
public enum TranscriptHealer {
    /// Synthesises terminal results for orphan ``MessagePart/toolCall`` parts in `records`.
    ///
    /// An orphan is a ``ToolCall`` whose ``ToolCall/id`` does not appear as the
    /// ``ToolResult/callId`` of any ``MessagePart/toolResult`` part anywhere
    /// in the transcript. For each orphan, a synthesised ``MessagePart/toolResult``
    /// is appended to the same message's `contentParts` immediately after the
    /// originating call. Messages without orphan calls are returned unchanged.
    ///
    /// The synthesised result carries:
    /// - `callId` matching the orphan's ``ToolCall/id``
    /// - `errorKind = .cancelled`
    /// - A content string explaining the call was interrupted, including the
    ///   original arguments string so the user (and the model) can see what
    ///   was attempted.
    public static func heal(_ records: [ChatMessageRecord]) -> [ChatMessageRecord] {
        let resultIDs = collectResultCallIDs(from: records)
        var healed: [ChatMessageRecord] = []
        healed.reserveCapacity(records.count)
        for record in records {
            healed.append(healRecord(record, resultIDs: resultIDs))
        }
        return healed
    }

    /// Synthesises terminal results for orphan ``MessagePart/toolCall`` parts in a
    /// single message's `contentParts`.
    ///
    /// `resultIDs` is the set of ``ToolResult/callId`` values present *anywhere*
    /// in the transcript — orphans are determined transcript-wide, but
    /// synthesised results are inserted into the same message that contains
    /// the orphan call so persistence round-trips remain stable.
    public static func healParts(
        _ parts: [MessagePart],
        resultIDs: Set<String>
    ) -> [MessagePart] {
        // Fast path: no tool calls at all means nothing to heal.
        guard parts.contains(where: { $0.toolCallContent != nil }) else { return parts }

        var healed: [MessagePart] = []
        healed.reserveCapacity(parts.count)
        // Track ids whose results already appear *within this message* — calls
        // and their results frequently land in the same assistant turn, and we
        // must not double-insert when a result is present in either the same
        // record or elsewhere in the transcript.
        var resolvedInThisMessage: Set<String> = []
        for part in parts {
            if case .toolResult(let r) = part {
                resolvedInThisMessage.insert(r.callId)
            }
        }

        for part in parts {
            healed.append(part)
            guard case .toolCall(let call) = part else { continue }
            if resultIDs.contains(call.id) || resolvedInThisMessage.contains(call.id) {
                continue
            }
            healed.append(.toolResult(synthesiseResult(for: call)))
            // Mark resolved so a duplicate orphan call with the same id (rare
            // but possible if a backend retried before the host crashed) gets
            // exactly one synthesised result.
            resolvedInThisMessage.insert(call.id)
        }
        return healed
    }

    // MARK: - Internal helpers

    static func collectResultCallIDs(from records: [ChatMessageRecord]) -> Set<String> {
        var ids: Set<String> = []
        for record in records {
            for part in record.contentParts {
                if case .toolResult(let r) = part {
                    ids.insert(r.callId)
                }
            }
        }
        return ids
    }

    static func healRecord(
        _ record: ChatMessageRecord,
        resultIDs: Set<String>
    ) -> ChatMessageRecord {
        let healedParts = healParts(record.contentParts, resultIDs: resultIDs)
        if healedParts.count == record.contentParts.count {
            return record
        }
        var copy = record
        copy.contentParts = healedParts
        return copy
    }

    static func synthesiseResult(for call: ToolCall) -> ToolResult {
        ToolResult(
            callId: call.id,
            content: "Tool call was interrupted before completion. Original arguments: \(call.arguments)",
            errorKind: .cancelled
        )
    }
}
