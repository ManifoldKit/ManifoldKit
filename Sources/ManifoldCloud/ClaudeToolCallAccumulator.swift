#if CloudSaaS
import Foundation
import ManifoldInference

/// Stateful accumulator for Claude streaming and whole-message `tool_use` blocks.
final class ClaudeToolCallAccumulator {
    private let accumulator = StreamingToolCallAccumulator()
    private var toolUseIndexes: Set<Int> = []
    private var toolUseEmittedDelta: Set<Int> = []
    private var toolUseFinalized: Set<Int> = []
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func handleToolUseBlockStart(
        _ start: ClaudePayloadParser.ToolUseBlockStart,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        let key = "\(start.index)"
        accumulator.upsert(key: key, id: start.id, name: start.name, argumentsDelta: nil)
        toolUseIndexes.insert(start.index)
        continuation.yield(.toolCallStart(callId: start.id, name: start.name))
        accumulator.markStarted(key: key)
    }

    func handleInputJSONDelta(
        _ delta: ClaudePayloadParser.InputJSONDelta,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        let key = "\(delta.index)"
        accumulator.upsert(key: key, id: nil, name: nil, argumentsDelta: delta.partialJSON)
        let resolvedId = accumulator.resolvedId(forKey: key)
        if !delta.partialJSON.isEmpty {
            continuation.yield(.toolCallArgumentsDelta(callId: resolvedId, textDelta: delta.partialJSON))
            toolUseEmittedDelta.insert(delta.index)
        }
    }

    func finalizeToolUse(
        at index: Int,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        guard toolUseIndexes.contains(index), !toolUseFinalized.contains(index) else { return }
        let key = "\(index)"
        guard let entry = accumulator.entriesByKey[key], !entry.name.isEmpty else { return }
        let resolvedId = !entry.id.isEmpty ? entry.id : "claude-call-\(key)"
        if !toolUseEmittedDelta.contains(index) {
            continuation.yield(.toolCallArgumentsDelta(callId: resolvedId, textDelta: "{}"))
            toolUseEmittedDelta.insert(index)
        }
        let args = entry.arguments.isEmpty ? "{}" : entry.arguments
        continuation.yield(.toolCall(ToolCall(id: resolvedId, toolName: entry.name, arguments: args)))
        toolUseFinalized.insert(index)
    }

    func finalizePendingToolUses(continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        guard !cancelled else { return }
        for idx in toolUseIndexes.sorted() {
            finalizeToolUse(at: idx, continuation: continuation)
        }
    }

    func isToolUseIndex(_ index: Int) -> Bool {
        toolUseIndexes.contains(index)
    }

    func handleWholeMessageToolUseBlocks(
        _ calls: [ClaudePayloadParser.WholeToolUseBlock],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        for call in calls {
            let key = "whole-\(call.id.isEmpty ? UUID().uuidString : call.id)"
            accumulator.upsert(key: key, id: call.id, name: call.name, argumentsDelta: call.serializedInput)
            let resolvedId = accumulator.resolvedId(forKey: key)
            continuation.yield(.toolCallStart(callId: resolvedId, name: call.name))
            accumulator.markStarted(key: key)
            continuation.yield(.toolCallArgumentsDelta(callId: resolvedId, textDelta: call.serializedInput))
            continuation.yield(.toolCall(ToolCall(id: resolvedId, toolName: call.name, arguments: call.serializedInput)))
        }
    }
}
#endif
