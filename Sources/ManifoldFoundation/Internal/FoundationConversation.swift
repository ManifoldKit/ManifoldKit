#if canImport(FoundationModels)
import Foundation
import FoundationModels
import ManifoldContract

/// Lowers the canonical request, never the SDK's previous mutable transcript.
/// Tool records remain text because MK's dispatch loop owns execution/approval;
/// installing native SDK tools would introduce a second executor.
@available(iOS 26, macOS 26, *)
struct FoundationConversation {
    let entries: [Transcript.Entry]
    let prompt: String
    let systemInstructions: String?

    init(history: [StructuredMessage], fallbackPrompt: String) throws {
        var turns: [(role: String, text: String)] = []
        var systems: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for message in history {
            guard ["system", "user", "assistant", "tool"].contains(message.role) else {
                throw InferenceError.inferenceFailure("FoundationBackend does not support history role '\(message.role)'.")
            }
            var fragments: [String] = []
            for part in message.parts {
                switch part {
                case .text(let text): fragments.append(text)
                case .toolCall(let call):
                    guard message.role == "assistant" else {
                        throw InferenceError.inferenceFailure("FoundationBackend tool calls require the assistant role.")
                    }
                    fragments.append("\nTool call: " + String(decoding: try encoder.encode(call), as: UTF8.self))
                case .toolResult(let result):
                    guard message.role == "tool" else {
                        throw InferenceError.inferenceFailure("FoundationBackend tool results require the tool role.")
                    }
                    fragments.append("\nTool result: " + String(decoding: try encoder.encode(result), as: UTF8.self))
                case .thinking:
                    // The text-only contract excludes private reasoning from context.
                    continue
                case .image, .audio, .generatedMedia:
                    throw InferenceError.inferenceFailure("FoundationBackend cannot replay media in conversation history.")
                }
            }
            let text = fragments.joined()
            if message.role == "system" { systems.append(text) }
            else { turns.append((message.role, text)) }
        }
        systemInstructions = systems.isEmpty ? nil : systems.joined(separator: "\n\n")

        if turns.last?.role == "user" {
            // The queue also supplies this user text as `prompt`. Consume it once.
            prompt = turns.removeLast().text
        } else if turns.last?.role == "tool" {
            var results: [String] = []
            while turns.last?.role == "tool" { results.insert(turns.removeLast().text, at: 0) }
            prompt = results.joined(separator: "\n")
        } else if turns.isEmpty {
            prompt = fallbackPrompt
        } else {
            // There is no pending user/tool turn to generate against. Guessing
            // would duplicate an earlier user prompt or silently invent a turn.
            throw InferenceError.inferenceFailure("FoundationBackend history must end with a user message or tool result.")
        }
        entries = turns.map { turn in
            let segments: [Transcript.Segment] = [.text(.init(content: turn.text))]
            if turn.role == "assistant" {
                return .response(.init(assetIDs: [], segments: segments))
            }
            return .prompt(.init(segments: segments))
        }
    }
}
#endif
