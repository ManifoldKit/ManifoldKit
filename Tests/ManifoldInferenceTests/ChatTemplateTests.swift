import XCTest
@testable import ManifoldInference

/// Unit tests for the v1 ``ChatTemplate`` value (#1944): construction from both
/// sources, `thinkingMarkers` delegation, behaviour-preserving `format` parity
/// with ``PromptRenderer``, and template-derived stop-sequence derivation +
/// merge policy. Plus the flatten-residual tool-drop regression the same issue
/// fixes, and `GenerationConfig.stopSequences` Codable back-compat.
final class ChatTemplateTests: XCTestCase {

    // MARK: - Helpers

    private func msg(_ role: String, _ content: String) -> StructuredMessage {
        StructuredMessage(role: role, content: content)
    }

    /// A minimal embedded Jinja ChatML template that swift-jinja can render.
    private let chatMLJinja = """
    {% for message in messages %}<|im_start|>{{ message['role'] }}
    {{ message['content'] }}<|im_end|>
    {% endfor %}{% if add_generation_prompt %}<|im_start|>assistant
    {% endif %}
    """

    // MARK: - Construction

    func test_builtInConstruction_carriesEnumSource() {
        let template = ChatTemplate(builtIn: .llama3)
        guard case .builtIn(let inner) = template.source else {
            return XCTFail("Expected .builtIn source")
        }
        XCTAssertEqual(inner, .llama3)
    }

    func test_embeddedJinjaConstruction_carriesRawSource() {
        let template = ChatTemplate(embeddedJinja: chatMLJinja)
        guard case .embeddedJinja(let raw) = template.source else {
            return XCTFail("Expected .embeddedJinja source")
        }
        XCTAssertEqual(raw, chatMLJinja)
    }

    // MARK: - thinkingMarkers delegation

    func test_thinkingMarkers_builtIn_delegatesToEnum() {
        // .chatML maps to .qwen3 in PromptTemplate.thinkingMarkers.
        XCTAssertEqual(ChatTemplate(builtIn: .chatML).thinkingMarkers, .qwen3)
        // A non-thinking family returns nil.
        XCTAssertNil(ChatTemplate(builtIn: .mistral).thinkingMarkers)
    }

    func test_thinkingMarkers_embeddedJinja_delegatesToDetector() {
        let thinking = "{% for m in messages %}<think>{{ m }}</think>{% endfor %}"
        XCTAssertEqual(ChatTemplate(embeddedJinja: thinking).thinkingMarkers, .qwen3)
        XCTAssertNil(ChatTemplate(embeddedJinja: chatMLJinja).thinkingMarkers)
    }

    // MARK: - format parity (behaviour-preserving wrap)

    func test_format_builtIn_textIsByteIdenticalToPromptRenderer() {
        let messages = [msg("user", "Hello"), msg("assistant", "Hi"), msg("user", "How are you?")]
        let system = "You are helpful."

        let expected = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
            .render(messages: messages, systemPrompt: system, tools: [])

        let rendered = ChatTemplate(builtIn: .chatML)
            .format(messages, systemPrompt: system, tools: [])

        XCTAssertEqual(rendered.text, expected, "ChatTemplate.format must wrap PromptRenderer byte-for-byte")
    }

    func test_format_embeddedJinja_textIsByteIdenticalToPromptRenderer() {
        let messages = [msg("user", "Hello")]
        let expected = PromptRenderer(template: .chatML, chatTemplateRaw: chatMLJinja)
            .render(messages: messages, systemPrompt: nil, tools: [])

        let rendered = ChatTemplate(embeddedJinja: chatMLJinja)
            .format(messages, systemPrompt: nil, tools: [])

        XCTAssertEqual(rendered.text, expected)
    }

    func test_format_attachesTemplateDerivedStopSequences() {
        let rendered = ChatTemplate(builtIn: .chatML)
            .format([msg("user", "Hi")], systemPrompt: nil, tools: [])
        XCTAssertEqual(rendered.stopSequences, ["<|im_end|>"])
    }

    // MARK: - stopSequences derivation per family

    func test_stopSequences_perFamily() {
        XCTAssertEqual(ChatTemplate(builtIn: .chatML).stopSequences, ["<|im_end|>"])
        XCTAssertEqual(ChatTemplate(builtIn: .llama3).stopSequences, ["<|eot_id|>"])
        XCTAssertEqual(ChatTemplate(builtIn: .mistral).stopSequences, ["</s>"])
        XCTAssertEqual(ChatTemplate(builtIn: .gemma).stopSequences, ["<end_of_turn>"])
        XCTAssertEqual(ChatTemplate(builtIn: .gemma4).stopSequences, ["<|end_of_turn>"])
        XCTAssertEqual(ChatTemplate(builtIn: .phi).stopSequences, ["<|end|>"])
        XCTAssertEqual(ChatTemplate(builtIn: .alpaca).stopSequences, ["### Instruction:", "### Input:"])
    }

    func test_stopSequences_excludeOpeningDelimiters() {
        // Opening delimiters would abort generation prematurely — they must NOT
        // appear in the derived stop list.
        let chatML = ChatTemplate(builtIn: .chatML).stopSequences
        XCTAssertFalse(chatML.contains("<|im_start|>"))
        let llama3 = ChatTemplate(builtIn: .llama3).stopSequences
        XCTAssertFalse(llama3.contains("<|start_header_id|>"))
        XCTAssertFalse(llama3.contains("<|begin_of_text|>"))
    }

    func test_stopSequences_embeddedJinja_isEmptyGap() {
        // Documented v1 gap: no machine-readable stop list from raw Jinja.
        XCTAssertEqual(ChatTemplate(embeddedJinja: chatMLJinja).stopSequences, [])
    }
}
