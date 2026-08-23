import Foundation

/// The known tool-call dialect families a model/backend may emit.
///
/// Each family names a distinct on-the-wire shape for tool calls, derived from
/// the cross-family chat-template study in
/// `docs/plans/tool-calling-architecture.md`.
/// A family says *how* a call is delimited and encoded — not whether the weights
/// can actually tool-call.
public enum ToolCallDialectFamily: String, Codable, Sendable, CaseIterable {
    /// Hermes-style `<tool_call>\n{json}\n</tool_call>`.
    case hermes
    /// Qwen2.5-Instruct `<tool_call>\n{json}\n</tool_call>` (same delimiters as Hermes; kept distinct so backends can report the family they actually selected).
    case qwen
    /// gemma `<|tool_call>call:NAME{…}<|end_of_turn>` with custom `key:value` arguments
    /// (the call is terminated by the turn delimiter — there is no dedicated close-tool tag).
    case gemma
    /// Llama-3.1 `<|python_tag|>name.call(…)` (the python-tag custom-tool path; bare-JSON calls have no delimiter).
    case llamaPythonTag
    /// Mistral `[TOOL_CALLS] [{…}]`.
    case mistral
    /// A backend-specific dialect not matched by a named family.
    case custom
    /// Dialect not yet determined (the conservative default).
    case unknown
}

/// How a tool call encodes its arguments.
public enum ToolCallArgEncoding: String, Codable, Sendable {
    /// A JSON object (Hermes, Qwen, Mistral, Llama bare-JSON).
    case json
    /// Custom `key:value` / `key="val"` pairs (gemma, Llama python-tag).
    case keyValue
    /// A backend-specific encoding not covered above.
    case custom
}

/// How cleanly a tool call can be extracted from the model's output stream.
///
/// A predictive signal: `buried` calls (no opening delimiter, prose-embedded)
/// are the configuration most prone to parse failure — soak first, expect
/// salvage burden. See the `extractability` column in
/// `docs/plans/tool-calling-architecture.md`.
public enum ToolCallExtractability: String, Codable, Sendable {
    /// Delimited and unambiguous (Hermes, Qwen, gemma, Mistral).
    case clean
    /// No opening delimiter / prose-embedded — parse-failure prone (Llama custom-tool bare JSON).
    case buried
    /// The template carries no tools block — the model cannot express tools at all (Phi-4).
    case toolLess
}

/// The call dialect a backend selects for tool calls — the delimiters, argument
/// encoding, and extractability that describe *how* a (model × backend × renderer)
/// emits tool calls on the wire.
///
/// This is the static, *interface* fact ("which dialect"), not the empirical
/// verdict ("does it genuinely tool-call"). A backend that already picks a
/// dialect internally (e.g. llama.cpp's per-family markers) can surface it here
/// instead of discarding it at the capability boundary. See
/// `docs/plans/tool-calling-architecture.md` for the cross-family descriptor table.
public struct ToolCallDialect: Sendable, Codable, Equatable, Hashable {
    /// The dialect family this call belongs to.
    public let family: ToolCallDialectFamily

    /// The token opening a tool call (e.g. `<tool_call>`), or `nil` where the
    /// call has no opening delimiter (Llama bare-JSON custom tools).
    public let openDelimiter: String?

    /// The token closing a tool call (e.g. `</tool_call>`), or `nil` where the
    /// call has no closing delimiter.
    public let closeDelimiter: String?

    /// How the call encodes its arguments.
    public let argEncoding: ToolCallArgEncoding

    /// How cleanly the call can be extracted from the output stream.
    public let extractability: ToolCallExtractability

    public init(
        family: ToolCallDialectFamily = .unknown,
        openDelimiter: String? = nil,
        closeDelimiter: String? = nil,
        argEncoding: ToolCallArgEncoding = .json,
        extractability: ToolCallExtractability = .clean
    ) {
        self.family = family
        self.openDelimiter = openDelimiter
        self.closeDelimiter = closeDelimiter
        self.argEncoding = argEncoding
        self.extractability = extractability
    }

    // MARK: - Canonical presets

    /// Hermes-2-Pro: `<tool_call>\n{json}\n</tool_call>`.
    public static let hermes = ToolCallDialect(
        family: .hermes,
        openDelimiter: "<tool_call>",
        closeDelimiter: "</tool_call>",
        argEncoding: .json,
        extractability: .clean
    )

    /// Qwen2.5-Instruct: `<tool_call>\n{json}\n</tool_call>`.
    public static let qwen = ToolCallDialect(
        family: .qwen,
        openDelimiter: "<tool_call>",
        closeDelimiter: "</tool_call>",
        argEncoding: .json,
        extractability: .clean
    )

    /// gemma: `<|tool_call>call:NAME{…}<|end_of_turn>` with custom `key:value` args.
    /// The call is terminated by the turn delimiter `<|end_of_turn>` — Gemma has no
    /// dedicated close-tool tag — matching the runtime parser (`LlamaToolMarkers`
    /// `gemma4OpenTag`/`gemma4EndTurn`; `ToolCallTransform` "`<|tool_call>`…`<|end_of_turn>`").
    public static let gemma = ToolCallDialect(
        family: .gemma,
        openDelimiter: "<|tool_call>",
        closeDelimiter: "<|end_of_turn>",
        argEncoding: .keyValue,
        extractability: .clean
    )

    /// Mistral-v0.3: `[TOOL_CALLS] [{…}]`.
    public static let mistral = ToolCallDialect(
        family: .mistral,
        openDelimiter: "[TOOL_CALLS]",
        closeDelimiter: nil,
        argEncoding: .json,
        extractability: .clean
    )

    /// Llama-3.1 python-tag custom tool: `<|python_tag|>name.call(…)`. Bare-JSON
    /// Llama calls (no delimiter) are the `buried` configuration.
    public static let llamaPythonTag = ToolCallDialect(
        family: .llamaPythonTag,
        openDelimiter: "<|python_tag|>",
        closeDelimiter: nil,
        argEncoding: .keyValue,
        extractability: .buried
    )
}
