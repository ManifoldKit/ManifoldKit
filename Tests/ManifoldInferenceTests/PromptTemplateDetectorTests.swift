import XCTest
@testable import ManifoldInference

final class PromptTemplateDetectorTests: XCTestCase {

    // MARK: - Chat Template String Detection

    func test_detect_chatMLTemplate() {
        let template = "{% if messages[0] %}<|im_start|>system\n{{ content }}<|im_end|>{% endif %}"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .chatML)
    }

    func test_detect_llama3Template() {
        let template = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>{{ content }}<|eot_id|>"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .llama3)
    }

    func test_detect_mistralTemplate() {
        let template = "{{ bos_token }}{% for message in messages %}[INST] {{ message['content'] }} [/INST]{% endfor %}"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .mistral)
    }

    func test_detect_gemmaTemplate() {
        let template = "<start_of_turn>user\n{{ content }}<end_of_turn>\n<start_of_turn>model"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .gemma)
    }

    // Sabotage-verified: removing the `<|turn>` branch from detect(fromChatTemplate:)
    // causes the two gemma4 template tests below to fail.

    func test_detect_gemma4Template() {
        let template = "<|turn>user\n{{ content }}<|end_of_turn>\n<|turn>model"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .gemma4)
    }

    func test_detect_gemma4Template_beatsGemma3() {
        // A transitional template that contains both delimiters should resolve to gemma4
        // because <|turn> is the more specific Gemma 4 marker.
        let template = "<|turn>user\n<start_of_turn>legacy hint<|end_of_turn>\n<|turn>model"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .gemma4)
    }

    func test_detect_phiTemplate() {
        let template = "<|system|>\n{{ system }}<|end|>\n<|user|>\n{{ content }}<|end|>\n<|assistant|>"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .phi)
    }

    func test_detect_alpacaTemplate() {
        let template = "### Instruction:\n{{ instruction }}\n\n### Input:\n{{ input }}\n\n### Response:"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .alpaca)
    }

    func test_detect_unknownTemplate_defaultsChatML() {
        let template = "some completely unknown template format"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .chatML)
    }

    // MARK: - Thinking Marker Detection from Chat Template

    func test_detectThinkingMarkers_qwen3Template() {
        // Realistic Qwen3 chat template excerpt — both halves of the pair appear.
        let template = "{% for m in messages %}{{ m.role }}: {{ m.content }}{% endfor %}<think>{{ thinking }}</think>"
        XCTAssertEqual(PromptTemplateDetector.detectThinkingMarkers(from: template), .qwen3)
    }

    func test_detectThinkingMarkers_plainChatML_returnsNil() {
        // Standard ChatML template — no thinking markers anywhere.
        let template = "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}"
        XCTAssertNil(PromptTemplateDetector.detectThinkingMarkers(from: template),
                     "Plain ChatML must not be misidentified as a thinking model")
    }

    func test_detectThinkingMarkers_partialMatch_openWithoutClose_returnsNil() {
        // `<think>` is present but `</think>` is missing — should NOT report .qwen3.
        let template = "{{ messages[0].content }} <think>partial..."
        XCTAssertNil(PromptTemplateDetector.detectThinkingMarkers(from: template),
                     "An open tag with no closer must not match a marker family")
    }

    func test_detectThinkingMarkers_partialMatch_closeWithoutOpen_returnsNil() {
        let template = "{{ messages[0].content }} </think>tail"
        XCTAssertNil(PromptTemplateDetector.detectThinkingMarkers(from: template))
    }

    func test_detectThinkingMarkers_mistralReasoningTemplate() {
        let template = "[INST] {{ content }} [/INST] <thinking>{{ reasoning }}</thinking>"
        XCTAssertEqual(PromptTemplateDetector.detectThinkingMarkers(from: template), .mistralReasoning)
    }

    func test_detectThinkingMarkers_phi4Template() {
        let template = "<|user|>\n{{ content }}<|end|>\n<|assistant|>\n<reasoning>{{ analysis }}</reasoning>"
        XCTAssertEqual(PromptTemplateDetector.detectThinkingMarkers(from: template), .phi4)
    }

    func test_detectThinkingMarkers_reflectionTemplate() {
        let template = "{{ content }}<reflection>{{ critique }}</reflection>"
        XCTAssertEqual(PromptTemplateDetector.detectThinkingMarkers(from: template), .reflection)
    }

    func test_detectThinkingMarkers_gemma4Template() {
        // Gemma 4's thinking turn signature: open marker is `<|turn>think\n`,
        // close is the standard `<|end_of_turn>` delimiter.
        let template = "<|turn>think\n{{ analysis }}<|end_of_turn>\n<|turn>model\n{{ content }}<|end_of_turn>"
        XCTAssertEqual(PromptTemplateDetector.detectThinkingMarkers(from: template), .gemma4)
    }

    func test_detectThinkingMarkers_emptyTemplate_returnsNil() {
        XCTAssertNil(PromptTemplateDetector.detectThinkingMarkers(from: ""))
    }

    // ThinkingMarkers.fromChatTemplate is the public entry point that delegates
    // to the detector — pin one case to ensure the surface stays wired.
    func test_thinkingMarkers_fromChatTemplate_publicSurface() {
        let template = "<think>{{ x }}</think>"
        XCTAssertEqual(ThinkingMarkers.fromChatTemplate(template), .qwen3)
        XCTAssertNil(ThinkingMarkers.fromChatTemplate("plain text only"))
    }

    // MARK: - Architecture Detection

    func test_detect_fromArchitecture_llama() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "llama"), .chatML)
    }

    func test_detect_fromArchitecture_mistral() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "mistral"), .mistral)
    }

    func test_detect_fromArchitecture_gemma() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma"), .gemma)
    }

    func test_detect_fromArchitecture_gemma2() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma2"), .gemma)
    }

    func test_detect_fromArchitecture_gemma4() {
        // The chat-template path is the authoritative signal for Gemma 4 detection;
        // architecture lookup is a best-effort fallback keyed on the plausible identifiers.
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma4"), .gemma4)
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma-4"), .gemma4)
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "GEMMA4"), .gemma4)
    }

    func test_detect_fromArchitecture_gemma_unchanged() {
        // Regression: bare "gemma" and "gemma2" must keep mapping to .gemma, not .gemma4.
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma"), .gemma)
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma2"), .gemma)
    }

    func test_detect_fromArchitecture_phi() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "phi"), .phi)
    }

    func test_detect_fromArchitecture_phi3() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "phi3"), .phi)
    }

    func test_detect_fromArchitecture_unknown_defaultsChatML() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "mamba"), .chatML)
    }

    func test_detect_fromArchitecture_caseInsensitive() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "Llama"), .chatML)
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "MISTRAL"), .mistral)
    }

    // MARK: - Filename Heuristic

    func test_detect_fromFileName_containsLlama() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "Meta-Llama-3-8B-Q4.gguf"), .llama3)
    }

    func test_detect_fromFileName_containsMistral() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "mistral-7b-instruct-v0.2.gguf"), .mistral)
    }

    func test_detect_fromFileName_containsGemma() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "gemma-2-2b-it.gguf"), .gemma)
    }

    func test_detect_fromFileName_containsPhi() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "Phi-3-mini-4k-instruct.gguf"), .phi)
    }

    func test_detect_fromFileName_containsAlpaca() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "alpaca-7b.gguf"), .alpaca)
    }

    func test_detect_fromFileName_unknown_defaultsChatML() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "some-random-model.gguf"), .chatML)
    }

    // MARK: - Full Metadata Detection (Cascading Priority)

    func test_detect_fromMetadata_unambiguousArch_winsOverChatMLTemplate() {
        // phi3 architecture is unambiguous — even if the Jinja template contains
        // <|im_start|> in a compatibility branch, architecture must win.
        // Regression: Phi-4-mini-instruct was misidentified as ChatML (issue #464).
        let metadata = GGUFMetadata(
            generalName: "Phi-4-mini-instruct",
            generalArchitecture: "phi3",
            contextLength: 4096,
            chatTemplate: "{% if true %}<|im_start|>system\n{{ content }}<|im_end|>{% endif %}<|user|>\n{{ content }}<|end|>\n<|assistant|>",
            fileType: nil
        )
        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .phi,
                       "phi3 architecture must override a Jinja template that contains ChatML tokens")
    }

    func test_detect_fromMetadata_llama_chatTemplateWinsOverArchitecture() {
        // "llama" is ambiguous — many fine-tunes use different formats.
        // A ChatML Jinja template on an llama-arch model should still produce ChatML.
        let metadata = GGUFMetadata(
            generalName: "Mistral-7B",
            generalArchitecture: "llama",
            contextLength: 4096,
            chatTemplate: "<|im_start|>system\n{{ content }}<|im_end|>",
            fileType: nil
        )
        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .chatML)
    }

    func test_detect_fromMetadata_unambiguousArch_noTemplate_returnsArchFormat() {
        // Architecture is the primary check for unambiguous formats — "fallback" framing
        // no longer applies now that architecture is checked first.
        let metadata = GGUFMetadata(
            generalName: "SomeModel",
            generalArchitecture: "mistral",
            contextLength: 4096,
            chatTemplate: nil,
            fileType: nil
        )
        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .mistral)
    }

    func test_detect_fromMetadata_unambiguousArch_winsOverConflictingTemplate() {
        // Architecture wins for unambiguous formats even when the Jinja template
        // would map to a different non-ChatML format. Ensures the fix is not
        // limited to the ChatML collision case.
        let metadata = GGUFMetadata(
            generalName: "SomeGemmaModel",
            generalArchitecture: "gemma",
            contextLength: 4096,
            chatTemplate: "<|user|>\n{{ content }}<|end|>\n<|assistant|>",
            fileType: nil
        )
        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .gemma,
                       "gemma architecture must win over a phi-style Jinja template")
    }

    func test_detect_fromMetadata_llama_nonChatMLTemplateWinsOverArchitecture() {
        // "llama" is ambiguous: SmolLM2, TinyLlama, etc. use llama arch but different
        // chat formats. A llama3-header Jinja template on a llama-arch model must
        // produce .llama3, not the .chatML that the architecture alone would return.
        let metadata = GGUFMetadata(
            generalName: "SmolLM2-1.7B-Instruct",
            generalArchitecture: "llama",
            contextLength: 8192,
            chatTemplate: "<|begin_of_text|><|start_header_id|>system<|end_header_id|>{{ content }}<|eot_id|>",
            fileType: nil
        )
        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .llama3,
                       "llama3-format Jinja template must win over ambiguous llama architecture")
    }

    func test_detect_fromMetadata_fallsBackToName() {
        let metadata = GGUFMetadata(
            generalName: "gemma-2b-it",
            generalArchitecture: nil,
            contextLength: nil,
            chatTemplate: nil,
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .gemma)
    }

    func test_detect_fromMetadata_noInfo_defaultsChatML() {
        let metadata = GGUFMetadata(
            generalName: nil,
            generalArchitecture: nil,
            contextLength: nil,
            chatTemplate: nil,
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .chatML)
    }

    // MARK: - GGUF Metadata Fixture Variants (#518)

    /// Closes #518 — per-variant GGUF metadata fixtures proving
    /// `PromptTemplateDetector.detect(from:)` resolves every supported
    /// `PromptTemplate` case from realistic Jinja templates observed on actual
    /// Hugging Face GGUFs (Qwen2, Meta-Llama-3, Gemma 4, Mistral-7B, Phi-3).
    ///
    /// `LlamaBackend.capabilities.requiresPromptTemplate == true`, so
    /// `InferenceService` formats the prompt using whatever this detector returns.
    /// A regression here (e.g. `gemma4` silently collapsing to `gemma`, or a
    /// Qwen-style ChatML template misrouted to Phi) ships as malformed prompts
    /// with no failing test — this fixture pins one case per supported variant.
    ///
    /// Sabotage check: change the final `return .chatML` fallback in
    /// `detect(fromChatTemplate:)` to `return .llama3`. Every non-llama3 case
    /// in this fixture fails, and the Qwen2 case (whose architecture is not in
    /// the unambiguous list and therefore falls through to the chat-template
    /// path) also fails — proving the fixture actually exercises both branches.
    func test_fixture_perVariant_detectsCorrectTemplate() {
        let fixtures: [(name: String, metadata: GGUFMetadata, expected: PromptTemplate)] = [
            // Qwen2/Qwen3 ChatML — architecture "qwen2" is ambiguous, so the
            // <|im_start|> Jinja marker must route the detector to chatML.
            (
                "Qwen2.5 ChatML",
                GGUFMetadata(
                    generalName: "Qwen2.5-7B-Instruct",
                    generalArchitecture: "qwen2",
                    contextLength: 32_768,
                    chatTemplate: "{% for message in messages %}<|im_start|>{{ message.role }}\n{{ message.content }}<|im_end|>\n{% endfor %}<|im_start|>assistant\n",
                    fileType: nil
                ),
                .chatML
            ),
            // Meta-Llama-3 — `llama` architecture is ambiguous; the
            // <|start_header_id|> marker in the Jinja template must win.
            (
                "Meta-Llama-3 header",
                GGUFMetadata(
                    generalName: "Meta-Llama-3-8B-Instruct",
                    generalArchitecture: "llama",
                    contextLength: 8192,
                    chatTemplate: "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n{{ system }}<|eot_id|>",
                    fileType: nil
                ),
                .llama3
            ),
            // Gemma 4 — the named #518 regression: <|turn> must NOT be swallowed
            // by the older <start_of_turn> branch. A transitional template might
            // contain both; the <|turn> variant is the more specific signal.
            (
                "Gemma 4 turn",
                GGUFMetadata(
                    generalName: "gemma-4-9b-it",
                    generalArchitecture: "gemma4",
                    contextLength: 8192,
                    chatTemplate: "<|turn>user\n{{ content }}<|end_of_turn>\n<|turn>model\n",
                    fileType: nil
                ),
                .gemma4
            ),
            // Mistral — [INST] marker pair; architecture "mistral" is also
            // unambiguous, so both branches corroborate.
            (
                "Mistral INST",
                GGUFMetadata(
                    generalName: "Mistral-7B-Instruct-v0.2",
                    generalArchitecture: "mistral",
                    contextLength: 32_768,
                    chatTemplate: "{{ bos_token }}{% for message in messages %}[INST] {{ message.content }} [/INST]{% endfor %}",
                    fileType: nil
                ),
                .mistral
            ),
            // Phi 3 — regression anchor for #464 (Phi-4-mini-instruct silently
            // misidentified as ChatML because the Jinja template carried a
            // compatibility <|im_start|> branch). The phi3 architecture must
            // override the Jinja marker.
            (
                "Phi 3 architecture",
                GGUFMetadata(
                    generalName: "Phi-3-mini-4k-instruct",
                    generalArchitecture: "phi3",
                    contextLength: 4096,
                    chatTemplate: "<|user|>\n{{ content }}<|end|>\n<|assistant|>\n",
                    fileType: nil
                ),
                .phi
            ),
        ]

        for fixture in fixtures {
            XCTAssertEqual(
                PromptTemplateDetector.detect(from: fixture.metadata),
                fixture.expected,
                "\(fixture.name) fixture must resolve to \(fixture.expected.rawValue)"
            )
        }
    }
}
