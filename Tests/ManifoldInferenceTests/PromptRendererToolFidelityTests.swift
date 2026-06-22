import XCTest
@testable import ManifoldInference

/// Proves the #1957 Tier 3 / #1909 fail-fast: when a model's embedded chat
/// template is present but unrenderable and the caller requested tools, the
/// renderer must **throw** rather than silently degrade to the text-only enum
/// fallback (which renders tools only for `.gemma4` and drops them otherwise,
/// driving tool-calling success to ~0% with no visible error).
final class PromptRendererToolFidelityTests: XCTestCase {

    // A template swift-jinja cannot parse → the embedded render always misses.
    private let brokenTemplate = "{%- if broken"

    private func weatherTool() -> ToolDefinition {
        ToolDefinition(
            name: "get_weather",
            description: "Look up the weather.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
                "required": .array([.string("city")]),
            ])
        )
    }

    private func userMessage() -> [StructuredMessage] {
        [StructuredMessage(role: "user", content: "weather in Paris?")]
    }

    /// THE REGRESSION: unrenderable embedded template + tools + non-gemma enum
    /// must throw, not silently drop the tools.
    func test_failsFast_whenEmbeddedTemplateUnusableAndToolsRequested() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: brokenTemplate)
        XCTAssertThrowsError(
            try renderer.render(
                messages: userMessage(),
                systemPrompt: nil,
                tools: [weatherTool()]
            ),
            "An unusable embedded template with tools requested must throw, not drop tools silently."
        ) { error in
            // The error message should name the tool-drop cause so the host can act.
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("tool"),
                "Thrown error must explain the tool-fidelity failure; got: \(message)"
            )
        }
    }

    /// Plain chat (no tools) over the same unusable template must still fall back
    /// to the enum — there is nothing to drop, so degradation is safe.
    func test_fallsBack_whenNoToolsRequested() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: brokenTemplate)
        let out = try renderer.render(messages: userMessage(), systemPrompt: nil, tools: [])
        let enumOut = PromptTemplate.chatML.format(
            messages: [(role: "user", content: "weather in Paris?")],
            systemPrompt: nil
        )
        XCTAssertEqual(out, enumOut, "No tools → safe enum fallback, no throw.")
    }

    /// `.gemma4` renders tools natively in the enum fallback, so an unusable
    /// embedded template does NOT drop them — it must not throw.
    func test_doesNotThrow_whenEnumFallbackRendersToolsNatively() throws {
        let renderer = PromptRenderer(template: .gemma4, chatTemplateRaw: brokenTemplate)
        let out = try renderer.render(
            messages: userMessage(),
            systemPrompt: nil,
            tools: [weatherTool()]
        )
        XCTAssertFalse(out.isEmpty, "gemma4 enum fallback renders tools; must not throw.")
    }

    /// A usable embedded template that renders tools must succeed (no false
    /// positive on the fail-fast).
    func test_doesNotThrow_whenEmbeddedTemplateRenders() throws {
        // A minimal renderable ChatML-ish template (no tool block needed; it
        // renders successfully, so the fail-fast never fires).
        let usable = "{%- for m in messages %}{{ m.role }}: {{ m.content }}\n{%- endfor %}"
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: usable)
        let out = try renderer.render(
            messages: userMessage(),
            systemPrompt: nil,
            tools: [weatherTool()]
        )
        XCTAssertTrue(out.contains("weather in Paris?"), "Usable template must render and not throw.")
    }

    /// `renderAllowingToolDrop` is the lower-level primitive (used by
    /// `ChatTemplate.format`) that preserves the historical tool-dropping
    /// fallback — it must NOT throw even in the regression scenario.
    func test_renderAllowingToolDrop_doesNotThrow() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: brokenTemplate)
        let out = renderer.renderAllowingToolDrop(
            messages: userMessage(),
            systemPrompt: nil,
            tools: [weatherTool()]
        )
        XCTAssertFalse(out.isEmpty, "The tool-drop-permitting primitive falls back rather than throwing.")
    }
}
