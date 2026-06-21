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

    // MARK: - Embedded-Jinja stop-sequence derivation (#2008)

    /// A minimal Mistral-style Jinja template — `[INST]`/`[/INST]` delimiters,
    /// `</s>` end-of-turn. This mirrors the actual template shipped in
    /// Mistral-7B-Instruct-v0.3.gguf that triggered #2008.
    private let mistralJinja = """
    {{ bos_token }}{% for message in messages %}{% if message['role'] == 'user' %}\
    {{ '[INST] ' + message['content'] + ' [/INST]' }}{% elif message['role'] == 'assistant' %}\
    {{ message['content'] + eos_token}}{% else %}{{ raise_exception('Only user and assistant roles are supported!') }}\
    {% endif %}{% endfor %}
    """

    /// An embedded Mistral Jinja template must derive `</s>` as its stop
    /// sequence — NOT the ChatML default `<|im_end|>` (#2008).
    ///
    /// Before the fix, `embeddedJinja` always returned `[]`, leaving the
    /// backend without a stop signal; the llama.cpp backend then applied its
    /// own ChatML default, leaking `<|im_end|>` into Mistral output.
    func test_stopSequences_embeddedMistralJinja_derivesEndOfSentence() {
        let template = ChatTemplate(embeddedJinja: mistralJinja)
        let stops = template.stopSequences

        XCTAssertEqual(stops, ["</s>"], "Mistral embedded-Jinja must derive </s> not ChatML default; got: \(stops)")
        XCTAssertFalse(stops.contains("<|im_end|>"), "ChatML end token must never appear for a Mistral template")
    }

    /// A ChatML embedded-Jinja template must still derive `<|im_end|>` — guard
    /// against regressing the models #1944 already fixed.
    func test_stopSequences_embeddedChatMLJinja_derivesChatMLToken() {
        let template = ChatTemplate(embeddedJinja: chatMLJinja)
        let stops = template.stopSequences

        XCTAssertEqual(stops, ["<|im_end|>"], "ChatML embedded-Jinja must derive <|im_end|>; got: \(stops)")
    }

    /// A markerless embedded-Jinja template the detector can't classify must
    /// derive NO stop sequence — it must not inherit the ChatML default, which
    /// would re-introduce the leak #2008 fixes. (The detector falls back to
    /// `.chatML`; `stopSequences` must distinguish that from a real ChatML
    /// template.) Mirrors `ChatTemplateStopAndFlattenTests.test_mergePolicy_
    /// embeddedJinjaNoDefault_leavesEmpty` at the queue layer.
    func test_stopSequences_embeddedUnknownJinja_staysEmpty() {
        let markerless = "{% for m in messages %}{{ m['content'] }}{% endfor %}"
        let stops = ChatTemplate(embeddedJinja: markerless).stopSequences

        XCTAssertEqual(stops, [], "Unrecognised embedded-Jinja must contribute no stop sequence; got: \(stops)")
    }
}
