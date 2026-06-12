import Foundation
import ManifoldInference

/// Wire-shape parsing for the OpenAI Chat Completions streaming format.
///
/// These helpers cover the field-level JSON extraction (token, reasoning,
/// tool-call deltas, whole tool calls, finish reason, usage, prefill
/// progress) used by both the stateless ``CloudPayloadHandler/openAI``
/// surface and the stateful ``OpenAIStreamEventExtractor``.
///
/// Lifting them out of ``OpenAIBackend`` keeps the backend a thin host
/// (request building + lifecycle) and pins the wire-format vocabulary in
/// one place — the architect review of PR #1272 called the prior
/// arrangement (parsers as `static` methods on the backend class) an
/// orphaned responsibility that bloated `OpenAIBackend.swift` by ~140 LOC.
package enum OpenAIChatCompletionsPayloadParsing {

    // MARK: - Stateless SSEPayloadHandler surface

    /// Extract `choices[0].delta.content` from a streaming chunk.
    package static func extractToken(from payload: String) -> String? {
        parseToken(from: payload)
    }

    /// Stateless event extraction. The full event vocabulary
    /// (tool calls, reasoning handoff, usage, prefill progress) lives on
    /// ``OpenAIStreamEventExtractor`` because it requires cross-frame state.
    package static func extractEvents(from payload: String) -> [GenerationEvent] {
        if let token = extractToken(from: payload) {
            return [.token(token)]
        }
        return []
    }

    /// Extract `usage.{prompt_tokens, completion_tokens}` from the terminal
    /// chunk (`stream_options.include_usage = true`).
    package static func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let usage = parseUsage(from: payload) else { return nil }
        return (promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
    }

    // MARK: - Field-level parsers

    /// Extracts the content token from an OpenAI streaming response chunk.
    ///
    /// Expected format:
    /// ```json
    /// {"choices":[{"delta":{"content":"token"}}]}
    /// ```
    package static func parseToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    /// Extracts reasoning text from an OpenAI-compatible Chat Completions delta.
    ///
    /// Two shapes are recognised:
    /// ```json
    /// {"choices":[{"delta":{"reasoning_content":"..."}}]}
    /// {"choices":[{"delta":{"reasoning":"..."}}]}
    /// ```
    /// `reasoning_content` is used by DeepSeek R1 and OpenAI-compatible hosts
    /// that mirror DeepSeek's convention; `reasoning` is used by some newer
    /// OpenAI-hosted reasoning deployments. Anything else — including plain
    /// `content` — returns `nil` so the caller can fall back to the standard
    /// token extractor.
    package static func parseReasoningDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }
        if let content = delta["reasoning_content"] as? String, !content.isEmpty {
            return content
        }
        if let content = delta["reasoning"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    // MARK: - Tool-call delta parsing

    /// Decoded shape of one streaming `tool_calls[]` entry inside a `delta`.
    package struct ToolCallDelta {
        package let index: Int
        package let id: String?
        package let name: String?
        package let argumentsDelta: String?
    }

    /// Decoded shape of one whole `message.tool_calls[]` entry (non-streaming
    /// path or compat servers that deliver completed calls in a single chunk).
    package struct WholeToolCall {
        package let id: String
        package let name: String
        package let arguments: String
    }

    /// Parses `choices[0].delta.tool_calls[]` from a streaming chunk.
    ///
    /// Each entry carries an `index` (required), an `id` and `function.name`
    /// (typically only on the first delta for that index), and a
    /// `function.arguments` fragment (typically on subsequent deltas).
    /// Compat servers vary on whether `id` is repeated; the accumulator
    /// handles that by stickying the first non-empty value seen per index.
    package static func parseToolCallDeltas(from json: String) -> [ToolCallDelta] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let rawCalls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }

        var result: [ToolCallDelta] = []
        for raw in rawCalls {
            guard let index = raw["index"] as? Int else { continue }
            let id = raw["id"] as? String
            let function = raw["function"] as? [String: Any]
            let name = function?["name"] as? String
            let argumentsDelta = function?["arguments"] as? String
            result.append(ToolCallDelta(
                index: index,
                id: id,
                name: name,
                argumentsDelta: argumentsDelta
            ))
        }
        return result
    }

    /// Parses a whole `choices[0].message.tool_calls[]` array from a
    /// non-streaming response chunk.
    package static func parseWholeToolCalls(from json: String) -> [WholeToolCall] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        var result: [WholeToolCall] = []
        for raw in rawCalls {
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            let id = (raw["id"] as? String) ?? ""
            let arguments = (function["arguments"] as? String) ?? "{}"
            result.append(WholeToolCall(id: id, name: name, arguments: arguments))
        }
        return result
    }

    /// Parses `choices[0].finish_reason` (e.g. `"stop"`, `"tool_calls"`).
    package static func parseFinishReason(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let reason = firstChoice["finish_reason"] as? String,
              !reason.isEmpty else {
            return nil
        }
        return reason
    }

    /// Extracts token usage from an OpenAI streaming response chunk.
    ///
    /// The final chunk includes usage when `stream_options.include_usage` is set:
    /// ```json
    /// {"choices":[...],"usage":{"prompt_tokens":25,"completion_tokens":100,"total_tokens":125}}
    /// ```
    package static func parseUsage(from json: String) -> (promptTokens: Int, completionTokens: Int)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = parsed["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int else {
            return nil
        }
        return (prompt, completion)
    }

    // MARK: - Prefill progress

    package struct PrefillProgress {
        package let nPast: Int
        package let nTotal: Int
        package let tokensPerSecond: Double
    }

    package static func parsePrefillProgress(from json: String) -> PrefillProgress? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        let parsed: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = object
        } catch {
            return nil
        }
        guard let nPast = parsed["n_past"] as? Int,
              let nTotal = parsed["n_total"] as? Int else {
            return nil
        }
        let tokensPerSecond: Double
        if let value = parsed["tokens_per_second"] as? Double {
            tokensPerSecond = value
        } else if let value = parsed["tokens_per_second"] as? Int {
            tokensPerSecond = Double(value)
        } else {
            return nil
        }
        return PrefillProgress(
            nPast: nPast,
            nTotal: nTotal,
            tokensPerSecond: tokensPerSecond
        )
    }
}
