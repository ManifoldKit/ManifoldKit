@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class ChatViewModelSystemPromptContextTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeVM(backend: MockInferenceBackend) -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSession(title: "Test")
        return vm
    }

    // MARK: - Substitution works

    func test_systemPromptContext_substitutesTokens_beforeReachingBackend() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "The assistant greets {{name}}."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "The assistant greets Alice.",
            "systemPromptContext should substitute {{name}} before the prompt reaches the backend"
        )
    }

    // MARK: - Empty dict is a no-op

    func test_systemPromptContext_emptyDict_leavesPromptUnchanged() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "Hello {{name}}."
        vm.systemPromptContext = [:]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello {{name}}.",
            "An empty systemPromptContext must leave the prompt untouched"
        )
    }

    // MARK: - Missing token passes through verbatim

    func test_systemPromptContext_missingKey_leavesTokenVerbatim() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "Hello {{name}}, your role is {{role}}."
        vm.systemPromptContext = ["name": "Alice"] // role is intentionally absent

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello Alice, your role is {{role}}.",
            "Tokens whose key is missing from the dict must pass through unchanged so callers can spot them"
        )
    }

    // MARK: - Multiple occurrences of the same token

    func test_systemPromptContext_replacesAllOccurrencesOfSameToken() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "{{name}} likes {{name}}'s coffee. {{name}} drinks it daily."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Alice likes Alice's coffee. Alice drinks it daily.",
            "Every occurrence of the same {{key}} should be replaced, not just the first"
        )
    }

    // MARK: - Substitution is non-recursive

    func test_systemPromptContext_doesNotRecursivelyExpandValues() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "Hello {{first}}."
        // If substitution were recursive, "{{first}}" would expand to
        // "{{second}}" then to "Bob". Since we guarantee non-recursion, the
        // literal "{{second}}" must reach the backend.
        vm.systemPromptContext = ["first": "{{second}}", "second": "Bob"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello {{second}}.",
            "systemPromptContext must not recursively re-expand values, regardless of dict iteration order"
        )
    }

    // MARK: - Empty string value substitutes correctly

    func test_systemPromptContext_emptyStringValue_substitutesAsEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "Persona: {{persona}}|end"
        vm.systemPromptContext = ["persona": ""]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Persona: |end",
            "An empty-string value should erase the token, not leave it as a literal"
        )
    }

    // MARK: - Direct unit tests for applySystemPromptContext

    func test_applySystemPromptContext_emptyBraces_areIgnored() {
        // `{{}}` contains no word characters so `\w+` won't match — the token
        // should pass through verbatim even when the empty string is in the dict.
        let result = ChatViewModel.applySystemPromptContext(
            "Hello {{}} world",
            context: ["": "X"]
        )
        XCTAssertEqual(result, "Hello {{}} world",
            "Empty `{{}}` must not be substituted — `\\w+` requires at least one word character")
    }

    func test_applySystemPromptContext_unicodeKey_behavior() {
        // NSRegularExpression uses ICU's `\w`, which matches Unicode word characters,
        // so Cyrillic keys are matched and substituted.
        let result = ChatViewModel.applySystemPromptContext(
            "{{имя}}",
            context: ["имя": "Иван"]
        )
        XCTAssertEqual(result, "Иван",
            "ICU `\\w` matches Unicode word chars, so Cyrillic keys must be substituted")
    }

    func test_applySystemPromptContext_noDoubleBraces_returnsEarly() {
        // The early-exit guard `text.contains("{{")` should short-circuit before
        // touching the regex when there is nothing to substitute.
        let result = ChatViewModel.applySystemPromptContext(
            "No tokens here.",
            context: ["name": "Alice"]
        )
        XCTAssertEqual(result, "No tokens here.",
            "Text without `{{` must be returned unchanged (exercises the early-exit path)")
    }

    func test_applySystemPromptContext_missingKey_passesThrough() {
        // A key present in the text but absent from the dict must survive verbatim.
        let result = ChatViewModel.applySystemPromptContext(
            "Hello {{unknown}}",
            context: [:]
        )
        XCTAssertEqual(result, "Hello {{unknown}}",
            "An unrecognized `{{key}}` must pass through unchanged when the dict is empty")
    }

    // MARK: - Mid-conversation mutation between sends

    func test_systemPromptContext_mutationBetweenSends_appliesToSecondPrompt() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok", "ok"]
        let vm = await makeVM(backend: mock)
        vm.systemPrompt = "Talking to {{name}}."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()
        XCTAssertEqual(mock.lastSystemPrompt, "Talking to Alice.")

        // Mutate the dict between sends — the next generation should see the new value.
        vm.systemPromptContext = ["name": "Bob"]
        vm.inputText = "Hi again"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Talking to Bob.",
            "Updating systemPromptContext between sends should affect the next generation's effective prompt"
        )
    }
}
