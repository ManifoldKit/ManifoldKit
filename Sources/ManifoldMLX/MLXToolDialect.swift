#if MLX
import Foundation

/// Identifies the tool-call dialect a locally loaded MLX model uses.
///
/// Different model families emit tool invocations in different text formats.
/// `MLXToolDialect` is detected at load time by reading `config.json` from
/// the model directory, so the generate path can apply the right injection
/// and parsing strategy without guessing per token.
///
/// Currently supported dialects:
/// - `.qwen25` — Qwen 2.5 / Qwen 3 format: tools injected as a
///   `<tools>…</tools>` JSON block appended to the system message; model
///   emits `<tool_call>{"name":"…","arguments":{…}}</tool_call>`.
/// - `.unknown` — no recognised tool dialect; tool calling is a no-op.
public enum MLXToolDialect: Equatable, Sendable {
    /// Qwen 2.5 / Qwen 3 tool-call format.
    ///
    /// Tool definitions are serialised as a JSON array and wrapped in
    /// `<tools>…</tools>` tags appended to the system message (or injected
    /// as a synthetic system message when the caller did not supply one).
    /// The model responds with one or more `<tool_call>…</tool_call>` blocks,
    /// each containing a JSON object with `"name"` and `"arguments"` keys.
    case qwen25

    /// No recognised tool dialect — tool calling is disabled for this model.
    case unknown

    // MARK: - Detection

    /// Reads `config.json` inside `url` and returns the best-matching dialect.
    ///
    /// Detection is best-effort: a missing or unreadable config, or one that
    /// does not declare a recognised `model_type`, maps to `.unknown`.
    ///
    /// - Parameter url: The model directory URL (same one passed to
    ///   `MLXBackend.loadModel(from:plan:)`).
    /// - Returns: `.qwen25` when `config.json` reports `model_type == "qwen2"`
    ///   or `"qwen3"`; `.unknown` otherwise.
    public static func detect(at url: URL) -> MLXToolDialect {
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unknown
        }

        let modelType = (json["model_type"] as? String)?
            .lowercased()
            .trimmingCharacters(in: .whitespaces) ?? ""

        // qwen2 covers both Qwen 2.5 and earlier 2.x checkpoints;
        // qwen3 / qwen3_* are also compatible with the same prompt format.
        if modelType.hasPrefix("qwen2") || modelType.hasPrefix("qwen3") {
            return .qwen25
        }

        return .unknown
    }
}
#endif
