import Foundation

/// A static, template-derived **claim** about whether (and how) a model's chat
/// template expresses tool calls.
///
/// This is Layer 1 of the tool-call-conformance design (#2005): an honest
/// *claim*, not a measured *verdict*. It is produced by a pure substring/regex
/// parse of the Jinja chat template ManifoldKit already stores
/// (``ModelInfo/chatTemplateRaw``) — no engine, no trial-render, no live soak.
///
/// **How to read the claim:**
/// - **Negative is trustworthy.** When a template carries no tools guard at all
///   (e.g. Phi-4), tools are genuinely *not expressible* through that template —
///   ``toolsExpressible`` is `false` and a host should not attempt tool calling.
/// - **Positive is necessary-but-NOT-sufficient.** When a template *does* carry
///   a tools guard, this value claims the model "expresses tools in dialect X".
///   That is a precondition, not a guarantee: a base (non-instruct) checkpoint
///   often carries the instruct template verbatim yet cannot follow it. The host
///   verifies this claim itself by actually running the model — ManifoldKit
///   deliberately does **not** measure here (measurement is consumer-owned and
///   explicitly out of scope for Layer 1).
///
/// The parser is intentionally heuristic. It recognises the guard and call
/// dialect of the common open-weight families; an unrecognised-but-present guard
/// still reports ``toolsExpressible`` `true` with a `nil` ``declaredDialect``.
public struct ChatTemplateToolDescriptor: Sendable, Equatable, Hashable, Codable {

    /// The serialisation a model uses to encode tool-call *arguments*.
    ///
    /// Raw values are stable wire identifiers — never renumber or rename them; a
    /// persisted catalog claim decodes against these strings.
    public enum ArgEncoding: String, Sendable, Equatable, Hashable, Codable {
        /// JSON object, e.g. `{"location": "Paris"}` (Qwen, Hermes, Mistral).
        case json
        /// Newline-delimited `key: value` pairs (Gemma's `<|tool_call>` form).
        case keyValue
        /// `key=value` pairs (some Llama python-tag style calls).
        case keyEqualsValue
    }

    /// How cleanly a host can extract a tool call from the model's output.
    ///
    /// Raw values are stable wire identifiers — never renumber or rename them.
    public enum Extractability: String, Sendable, Equatable, Hashable, Codable {
        /// A distinct open/close delimiter brackets the call — trivial to scan.
        case clean
        /// The call is bare JSON or a `python_tag` blob with no reliable
        /// delimiter (Llama-3.1) — extractable, but requires heuristics and is
        /// easy to confuse with ordinary assistant prose. A host should still
        /// attempt extraction (the claim is positive), but must scan with the
        /// family heuristic rather than a delimiter, and treat a miss as
        /// "model emitted prose" rather than "malformed call".
        case buried
        /// The template cannot express tools at all.
        case toolless
    }

    /// The tool-call dialect a template *declares* it will emit, when one is
    /// recognised. `nil` when tools are not expressible or the dialect is
    /// present-but-unrecognised.
    public struct ToolCallDialect: Sendable, Equatable, Hashable, Codable {
        /// Opening delimiter the model wraps a tool call in, e.g. `<tool_call>`.
        /// `nil` for bare-JSON / python-tag dialects with no opener.
        public let openDelimiter: String?
        /// Closing delimiter, e.g. `</tool_call>`. `nil` when there is no opener.
        public let closeDelimiter: String?
        /// How the call's arguments are serialised.
        public let argEncoding: ArgEncoding

        public init(openDelimiter: String?, closeDelimiter: String?, argEncoding: ArgEncoding) {
            self.openDelimiter = openDelimiter
            self.closeDelimiter = closeDelimiter
            self.argEncoding = argEncoding
        }
    }

    /// `true` iff the chat template carries a tools guard — a necessary
    /// precondition for tool calling. See the type doc for why a `true` here is
    /// a *claim*, not a guarantee.
    public let toolsExpressible: Bool

    /// The recognised call dialect, or `nil` (not expressible / unrecognised).
    public let declaredDialect: ToolCallDialect?

    /// How cleanly tool calls can be extracted from model output.
    public let extractability: Extractability

    /// Parses a chat-template string into a tool-call claim.
    ///
    /// A `nil` or whitespace-only template yields a trustworthy negative:
    /// ``toolsExpressible`` `false`, ``extractability`` ``Extractability/toolless``.
    public init(parsingChatTemplate raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.toolsExpressible = false
            self.declaredDialect = nil
            self.extractability = .toolless
            return
        }

        // --- 0. Strip Jinja comments -------------------------------------------
        // `{# ... #}` comment blocks are inert text the renderer never emits, yet
        // they freely contain guard/delimiter literals (a commented-out
        // `{# {% if tools %} #}` or a "{# emits [TOOL_CALLS] #}" note). Remove
        // them before BOTH guard and dialect probing so a comment can never trip
        // a claim. Non-greedy, dot-matches-newline so multi-line comments go too.
        let commentless = raw.replacingOccurrences(
            of: #"(?s)\{#.*?#\}"#, with: "", options: .regularExpression
        )

        // --- 1. Guard detection -------------------------------------------------
        // Recognise the tools-block guard shapes from the evidence table. Jinja
        // whitespace-control variants (`{%-`/`-%}`) and extra inner spacing are
        // normalised by collapsing runs of whitespace before substring matching.
        let normalized = commentless
            // Drop Jinja whitespace-control markers (`{%-`/`{%+`/`-%}`/`+%}`) so
            // the trimmed/non-trimmed tag spellings all match the plain `{%`/`%}`
            // guard shapes below, then collapse runs of whitespace (including
            // newlines inside a multi-line tag) to single spaces.
            .replacingOccurrences(of: #"\{%[-+]?"#, with: "{%", options: .regularExpression)
            .replacingOccurrences(of: #"[-+]?%\}"#, with: "%}", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let guardShapes = [
            "{% if tools %}",            // gemma, Qwen ({%- if tools %} normalises to this)
            "{% if tools is not none",   // Mistral
            "{% for tool in tools",      // Hermes (iterates the tools list directly)
            "Environment: ipython",      // Llama-3.1 system preamble
            "[TOOL_CALLS]",              // Mistral call token (also a guard signal)
        ]
        let hasGuard = guardShapes.contains { normalized.contains($0) }

        guard hasGuard else {
            self.toolsExpressible = false
            self.declaredDialect = nil
            self.extractability = .toolless
            return
        }
        self.toolsExpressible = true

        // --- 2. Dialect mapping -------------------------------------------------
        // Order matters: probe for the most specific call markers first. The
        // checks read the comment-stripped template so delimiter literals are
        // matched verbatim but a commented-out literal cannot win. Ordering note:
        // `<|tool_call>` must be probed before the broader `<tool_call>` (the
        // latter is NOT a substring of the former — different leading char — so
        // there is no shadowing, but keeping Gemma ahead of Qwen documents intent
        // and guards against a future loosening of either literal).
        if commentless.contains("[TOOL_CALLS]") {
            // Mistral: [TOOL_CALLS] then a JSON array of calls.
            self.declaredDialect = ToolCallDialect(
                openDelimiter: "[TOOL_CALLS]", closeDelimiter: nil, argEncoding: .json
            )
            self.extractability = .clean
        } else if commentless.contains("<|tool_call>") {
            // Gemma: <|tool_call> with newline-delimited key: value args.
            self.declaredDialect = ToolCallDialect(
                openDelimiter: "<|tool_call>", closeDelimiter: "<|/tool_call>", argEncoding: .keyValue
            )
            self.extractability = .clean
        } else if commentless.contains("<tool_call>") {
            // Qwen / Hermes: <tool_call>…</tool_call> wrapping a JSON object.
            self.declaredDialect = ToolCallDialect(
                openDelimiter: "<tool_call>", closeDelimiter: "</tool_call>", argEncoding: .json
            )
            self.extractability = .clean
        } else if commentless.contains("Environment: ipython") || commentless.contains("python_tag") || commentless.contains("<|python_tag|>") {
            // Llama-3.1: bare JSON or a python_tag blob, no reliable delimiter.
            self.declaredDialect = ToolCallDialect(
                openDelimiter: nil, closeDelimiter: nil, argEncoding: .json
            )
            self.extractability = .buried
        } else {
            // Guard present but call dialect unrecognised — still a claim that
            // tools are expressible, just with no decoded dialect.
            self.declaredDialect = nil
            self.extractability = .clean
        }
    }
}
