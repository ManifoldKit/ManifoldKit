import XCTest
@testable import ManifoldInference

/// Proves the #2200 knob: `GenerationRuntimeHints.renderingMode` /
/// `PromptRenderer.render(…renderingMode:)` lets a caller opt a GGUF
/// generation into plain continuation-style rendering even when the loaded
/// model carries an embedded Jinja chat template — without forking
/// `PromptRenderer` and without changing the default.
final class PromptRendererCompletionRenderingModeTests: XCTestCase {

    // A minimal renderable embedded template. If `.completion` mode did not
    // actually bypass the Jinja render, this fixture would produce the
    // chat-template shaped output below instead of plain continuation text.
    private let embeddedTemplate = "{%- for m in messages %}{{ m.role }}: {{ m.content }}\n{%- endfor %}"

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

    private func history() -> [StructuredMessage] {
        [
            StructuredMessage(role: "user", content: "Once upon a time, a fox"),
            StructuredMessage(role: "assistant", content: "wandered into the forest."),
        ]
    }

    // MARK: - `.completion` flips rendering on a fixture with an embedded template

    /// THE FEATURE: with an embedded chat template present and renderable,
    /// `renderingMode: .completion` must bypass the Jinja render entirely and
    /// produce plain continuation text — not the chat-template-shaped output
    /// that `.chatTemplate` (or omitting the parameter) would produce.
    func test_completionMode_bypassesEmbeddedTemplate_onFixtureWithEmbeddedTemplate() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: embeddedTemplate)

        let completionOut = try renderer.render(
            messages: history(),
            systemPrompt: "Write a short story.",
            renderingMode: .completion
        )

        // The embedded template's own role-labelled shape ("user: …") must be
        // absent — proves the Jinja path did not run.
        XCTAssertFalse(
            completionOut.contains("user:") || completionOut.contains("assistant:"),
            "`.completion` must not go through the embedded Jinja template; got: \(completionOut)"
        )
        XCTAssertEqual(
            completionOut,
            "Write a short story.\n\nOnce upon a time, a fox\n\nwandered into the forest.",
            "`.completion` renders systemPrompt + message content joined by blank lines, no role labels."
        )

        // Sabotage check: the same fixture under `.chatTemplate` DOES produce
        // the role-labelled shape, so the assertion above is a real signal and
        // not a fixture artifact.
        let chatTemplateOut = try renderer.render(
            messages: history(),
            systemPrompt: "Write a short story.",
            renderingMode: .chatTemplate
        )
        XCTAssertTrue(
            chatTemplateOut.contains("user:") && chatTemplateOut.contains("assistant:"),
            "Sanity check: the fixture's embedded template renders role-labelled text under `.chatTemplate`."
        )
        XCTAssertNotEqual(completionOut, chatTemplateOut)
    }

    /// No embedded template at all: `.completion` still bypasses the enum
    /// chat-template fallback, producing plain text rather than e.g. ChatML's
    /// `<|im_start|>` delimiters.
    func test_completionMode_bypassesEnumFallback_whenNoEmbeddedTemplate() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
        let out = try renderer.render(
            messages: history(),
            systemPrompt: nil,
            renderingMode: .completion
        )
        XCTAssertFalse(out.contains("<|im_start|>"), "Must not use the ChatML enum delimiters.")
        XCTAssertEqual(out, "Once upon a time, a fox\n\nwandered into the forest.")
    }

    // MARK: - Tool precedence: `.completion` + tools falls back to `.chatTemplate`

    /// The documented precedence rule (#2200 caveat): when `tools` is
    /// non-empty, `.completion` is ignored — the render path falls back to
    /// `.chatTemplate` so tool declarations are never silently dropped.
    func test_completionMode_isIgnored_whenToolsPresent() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: embeddedTemplate)

        let completionWithTools = try renderer.render(
            messages: [StructuredMessage(role: "user", content: "weather in Paris?")],
            systemPrompt: nil,
            tools: [weatherTool()],
            renderingMode: .completion
        )
        let chatTemplateWithTools = try renderer.render(
            messages: [StructuredMessage(role: "user", content: "weather in Paris?")],
            systemPrompt: nil,
            tools: [weatherTool()],
            renderingMode: .chatTemplate
        )

        XCTAssertEqual(
            completionWithTools,
            chatTemplateWithTools,
            "Tools present must force `.chatTemplate` precedence over a `.completion` request."
        )
        XCTAssertTrue(
            completionWithTools.contains("user:"),
            "The chat-template fallback (not plain continuation text) must have rendered."
        )
    }

    // MARK: - Default path is unchanged

    /// Omitting `renderingMode` entirely (the overwhelming majority of call
    /// sites, pre- and post-#2200) must produce byte-identical output to the
    /// explicit `.chatTemplate` request — the knob does not perturb the
    /// default path.
    func test_defaultRenderingMode_isUnchanged() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: embeddedTemplate)

        let implicitDefault = try renderer.render(
            messages: history(),
            systemPrompt: "Write a short story."
        )
        let explicitChatTemplate = try renderer.render(
            messages: history(),
            systemPrompt: "Write a short story.",
            renderingMode: .chatTemplate
        )

        XCTAssertEqual(implicitDefault, explicitChatTemplate)
        XCTAssertTrue(implicitDefault.contains("user:"), "Default path still renders through the embedded template.")
    }

    /// `GenerationRuntimeHints()`'s default `renderingMode` is `.chatTemplate`
    /// — the hints-level default matches the renderer-level default so a
    /// caller who never touches the new field sees no behavior change.
    func test_generationRuntimeHints_defaultRenderingMode_isChatTemplate() {
        XCTAssertEqual(GenerationRuntimeHints().renderingMode, .chatTemplate)
    }
}
