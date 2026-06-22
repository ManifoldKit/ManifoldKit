import Foundation

/// The verdict of a static tool-call render round-trip — Layer 2 of the
/// tool-call-conformance design (#2005).
///
/// Layer 1 (``ChatTemplateToolDescriptor``, #2009) produces an honest *claim*
/// by parsing the chat template's text. Layer 2 closes the loop on that claim
/// **without live inference**: it feeds a fixed canonical tool-call
/// conversation through the very renderer the local backends use at generation
/// time (``JinjaPromptRenderer``) and checks that the rendered prompt actually
/// contains what the Layer-1 claim promised — the tool name (the `{% if tools %}`
/// branch fired and the tool definition reached the model) and, when the claim
/// declares a call delimiter, that delimiter (the assistant tool-call turn
/// rendered through the template's `{% for tool_call in … %}` branch).
///
/// This catches the regression class behind #1909: a template whose tools
/// guard parses as positive but whose render path silently drops the tool
/// grammar (because the renderer was fed a text-only projection, or the
/// template's branch never fires). A static descriptor cannot see that — only
/// actually rendering can.
///
/// ## Limitation: presence, not a parse verdict
///
/// This is a **presence** check, not a family-specific parse-back. It asserts
/// that the declared delimiter and the tool name appear in the rendered prompt;
/// it does **not** re-parse the rendered call with a family decoder. Full
/// round-trip parse-back (`ToolCallMarker.parseBody` and the per-family
/// `ToolCallMarkers`) lives in the companion backend targets (manifold-llama /
/// manifold-mlx), which own the actual extraction grammar — core deliberately
/// asserts only delimiter/tool-name PRESENCE here. A `.consistent` verdict
/// therefore means "the template renders the declared grammar", not "a model's
/// emitted call will parse cleanly" (that is Layer 3, a live soak, deferred).
public struct RenderConsistency: Sendable, Equatable {

    /// The outcome of the round-trip.
    public enum Status: Sendable, Equatable {
        /// The render contains every grammar element the Layer-1 claim promised.
        case consistent
        /// The render is missing the tool name and/or the declared delimiter —
        /// the template's tools grammar did not survive rendering (#1909 class).
        case inconsistent
        /// There is nothing to round-trip: the template carries no tools guard
        /// (a trustworthy negative claim) or there is no template at all.
        case notApplicable
    }

    /// The outcome.
    public let status: Status

    /// The Layer-1 claim this round-trip was checked against.
    public let claim: ChatTemplateToolDescriptor

    /// `true` iff the probe tool's name (`get_weather`) appeared in the render.
    public let toolDefinitionRendered: Bool

    /// `true`/`false` when the claim declares an open delimiter and we checked
    /// for it; `nil` when the claim declares no opener (bare-JSON / python-tag
    /// dialects such as Llama-3.1, which have nothing to assert presence of).
    public let declaredDelimiterRendered: Bool?

    /// Human-readable description of the discrepancy, naming exactly which check
    /// failed. Empty string when `status` is `.consistent`.
    public let detail: String
}

/// Runs the Layer-2 (#2005) static render round-trip for a chat template.
///
/// See ``RenderConsistency`` for what the verdict means and its presence-only
/// limitation. There is no live inference here — this is a deterministic,
/// offline check suitable for catalog-time validation and CI.
public enum RenderConsistencyChecker {

    /// The fixed probe tool every round-trip renders: a single string param so
    /// the `{% if tools %}` branch has a concrete definition to emit.
    private static let probeToolName = "get_weather"

    /// Round-trips a chat template against a canonical tool-call conversation.
    ///
    /// - Parameter chatTemplateRaw: the model's embedded `tokenizer.chat_template`
    ///   Jinja string (``ModelInfo/chatTemplateRaw``). `nil` or blank yields
    ///   ``RenderConsistency/Status/notApplicable``.
    /// - Returns: the round-trip verdict.
    public static func check(chatTemplateRaw: String?) -> RenderConsistency {
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: chatTemplateRaw)

        // A negative claim (no tools guard, or no template) is trustworthy — the
        // descriptor already reports it honestly and there is nothing to render
        // back. Don't manufacture a probe for a template that cannot express
        // tools; report notApplicable.
        guard let raw = chatTemplateRaw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              claim.toolsExpressible else {
            return RenderConsistency(
                status: .notApplicable,
                claim: claim,
                toolDefinitionRendered: false,
                declaredDelimiterRendered: nil,
                detail: "template does not express tools (no guard or no template); nothing to round-trip"
            )
        }

        let probeTool = ToolDefinition(
            name: probeToolName,
            description: "Returns current weather for a location.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object([
                        "type": .string("string"),
                        "description": .string("City name"),
                    ]),
                ]),
                "required": .array([.string("location")]),
            ])
        )

        // Canonical tool-call conversation: user question, assistant turn that
        // CALLS the tool (this exercises the template's
        // `{% for tool_call in message.tool_calls %}` delimiter branch), then a
        // tool-result turn. The assistant call turn is what makes the declared
        // delimiter appear via the template rather than as static text.
        let probeCall = ToolCall(
            id: "call_0",
            toolName: probeToolName,
            arguments: #"{"location":"Paris"}"#
        )
        let probe: [StructuredMessage] = [
            StructuredMessage(role: "user", content: "What's the weather in Paris?"),
            StructuredMessage(role: "assistant", parts: [.toolCall(probeCall)]),
            StructuredMessage(
                role: "tool",
                parts: [.toolResult(ToolResult(callId: "call_0", content: "sunny"))]
            ),
        ]

        guard let rendered = JinjaPromptRenderer.render(
            rawTemplate: raw,
            messages: probe,
            systemPrompt: nil,
            tools: [probeTool]
        ) else {
            return RenderConsistency(
                status: .inconsistent,
                claim: claim,
                toolDefinitionRendered: false,
                declaredDelimiterRendered: claim.declaredDialect?.openDelimiter == nil ? nil : false,
                detail: "template claims tools but failed to render"
            )
        }

        let toolDefinitionRendered = rendered.contains(probeToolName)

        // The delimiter check only applies when the claim declares an opener.
        // Bare-JSON / python-tag dialects (Llama-3.1) declare none — there is no
        // literal to assert presence of, so leave it nil and don't gate on it.
        let declaredDelimiter = claim.declaredDialect?.openDelimiter
        let declaredDelimiterRendered: Bool? = declaredDelimiter.map { rendered.contains($0) }

        var failures: [String] = []
        if !toolDefinitionRendered {
            failures.append("tool definition '\(probeToolName)' missing from render (tools branch did not fire / tools dropped)")
        }
        if let delimiter = declaredDelimiter, declaredDelimiterRendered == false {
            failures.append("declared open delimiter '\(delimiter)' missing from render")
        }

        let consistent = toolDefinitionRendered
            && (declaredDelimiterRendered == nil || declaredDelimiterRendered == true)

        return RenderConsistency(
            status: consistent ? .consistent : .inconsistent,
            claim: claim,
            toolDefinitionRendered: toolDefinitionRendered,
            declaredDelimiterRendered: declaredDelimiterRendered,
            detail: consistent ? "" : failures.joined(separator: "; ")
        )
    }
}
