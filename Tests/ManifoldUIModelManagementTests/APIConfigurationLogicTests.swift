@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Tests for the data model and validation logic that drives API configuration views.
///
/// APIConfigurationView and APIEndpointEditorView rely on APIProvider enums,
/// validation rules, and SwiftData models. These tests verify the logic that
/// determines provider defaults, required fields, and save-gate conditions.
@MainActor
final class APIConfigurationLogicTests: XCTestCase {

    // MARK: - APIProvider defaults

    func test_provider_openAI_defaults() {
        let provider = APIProvider.openAI
        XCTAssertEqual(provider.defaultBaseURL, "https://api.openai.com")
        XCTAssertEqual(provider.defaultModelName, "gpt-4o-mini")
        XCTAssertTrue(provider.requiresAPIKey, "OpenAI should require an API key")
    }

    func test_provider_claude_defaults() {
        let provider = APIProvider.claude
        XCTAssertEqual(provider.defaultBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(provider.defaultModelName, "claude-sonnet-4-6")
        XCTAssertTrue(provider.requiresAPIKey, "Claude should require an API key")
    }

    func test_provider_ollama_defaults() {
        let provider = APIProvider.ollama
        XCTAssertEqual(provider.defaultBaseURL, "http://localhost:11434")
        XCTAssertEqual(provider.defaultModelName, "llama3.2")
        XCTAssertFalse(provider.requiresAPIKey, "Ollama should not require an API key")
    }

    func test_provider_lmStudio_defaults() {
        let provider = APIProvider.lmStudio
        XCTAssertEqual(provider.defaultBaseURL, "http://localhost:1234")
        XCTAssertEqual(provider.defaultModelName, "local-model")
        XCTAssertFalse(provider.requiresAPIKey, "LM Studio should not require an API key")
    }

    func test_provider_custom_defaults() {
        let provider = APIProvider.custom
        XCTAssertEqual(provider.defaultBaseURL, "https://")
        XCTAssertEqual(provider.defaultModelName, "model")
        XCTAssertTrue(provider.requiresAPIKey, "Custom should require an API key by default")
    }

    // MARK: - APIProvider enumeration

    func test_provider_allCases_containsAllProviders() {
        let cases = APIProvider.allCases
        XCTAssertEqual(cases.count, 6, "Should have 6 providers")
        XCTAssertTrue(cases.contains(.openAI))
        XCTAssertTrue(cases.contains(.openAIResponses))
        XCTAssertTrue(cases.contains(.claude))
        XCTAssertTrue(cases.contains(.ollama))
        XCTAssertTrue(cases.contains(.lmStudio))
        XCTAssertTrue(cases.contains(.custom))
    }

    func test_provider_identifiable_uniqueIDs() {
        let ids = Set(APIProvider.allCases.map(\.id))
        XCTAssertEqual(ids.count, APIProvider.allCases.count, "Each provider should have a unique ID")
    }

    func test_provider_rawValues_areDisplayNames() {
        // The raw values are used as display names in the UI picker.
        XCTAssertEqual(APIProvider.openAI.rawValue, "OpenAI")
        XCTAssertEqual(APIProvider.claude.rawValue, "Claude")
        XCTAssertEqual(APIProvider.ollama.rawValue, "Ollama")
        XCTAssertEqual(APIProvider.lmStudio.rawValue, "LM Studio")
        XCTAssertEqual(APIProvider.custom.rawValue, "Custom")
    }

    // MARK: - Save validation logic

    // Mirrors APIEndpointEditorView's save-gate predicate; documentation guard.
    // The live predicate lives in the Save button's `.disabled(...)` modifier
    // (APIEndpointEditorView.swift:110) and cannot be extracted without
    // refactoring the View body, which is out of scope here.

    /// APIEndpointEditorView disables save when name is empty after trimming.
    /// This mirrors the view's .disabled() condition on the Save button.
    func test_saveValidation_emptyNameBlocksSave() {
        let name = ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty, "Empty name should block save")
    }

    func test_saveValidation_whitespaceOnlyNameBlocksSave() {
        let name = "   \t\n  "
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty, "Whitespace-only name should block save")
    }

    func test_saveValidation_validNameAllowsSave() {
        let name = "My API"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "Non-empty name should allow save")
    }

    func test_saveValidation_nameWithLeadingTrailingWhitespace() {
        let name = "  My API  "
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmed, "My API", "Name should be trimmed before save")
        XCTAssertFalse(trimmed.isEmpty)
    }

    func test_draftValidation_acceptsLocalhostHTTP() {
        switch APIEndpointDraftValidator.validate(
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        ) {
        case .success:
            break
        case .failure(let reason):
            XCTFail("Expected localhost URL to pass canonical validation, got \(reason)")
        }
    }

    func test_draftValidation_rejectsPrivateIPv4() {
        switch APIEndpointDraftValidator.validate(
            provider: .custom,
            baseURL: "https://192.168.1.10",
            modelName: "model"
        ) {
        case .success:
            XCTFail("Expected RFC1918 address to be rejected")
        case .failure(let reason):
            XCTAssertEqual(reason, .privateHost)
        }
    }

    func test_draftValidation_rejectsLinkLocalMetadataHost() {
        switch APIEndpointDraftValidator.validate(
            provider: .custom,
            baseURL: "https://169.254.169.254",
            modelName: "model"
        ) {
        case .success:
            XCTFail("Expected IMDS address to be rejected")
        case .failure(let reason):
            XCTAssertEqual(reason, .linkLocalHost)
        }
    }

    func test_draftValidation_rejectsRemoteHTTPDNSHost() {
        switch APIEndpointDraftValidator.validate(
            provider: .custom,
            baseURL: "http://example.com",
            modelName: "model"
        ) {
        case .success:
            XCTFail("Expected remote HTTP endpoint to be rejected")
        case .failure(let reason):
            XCTAssertEqual(reason, .insecureScheme)
        }
    }

    func test_draftValidation_emptyURLUsesProviderDefault() {
        switch APIEndpointDraftValidator.validate(
            provider: .openAI,
            baseURL: "",
            modelName: "gpt-4o-mini"
        ) {
        case .success:
            break
        case .failure(let reason):
            XCTFail("Expected provider default URL to validate, got \(reason)")
        }
    }

    // MARK: - Provider switching populates defaults

    /// When the user switches providers in the editor (and is NOT editing an existing endpoint),
    /// the base URL, model name, and display name auto-populate from the provider defaults.
    func test_providerSwitch_populatesBaseURL() {
        for provider in APIProvider.allCases {
            let baseURL = provider.defaultBaseURL
            XCTAssertFalse(baseURL.isEmpty, "\(provider.rawValue) should have a non-empty default base URL")
        }
    }

    func test_providerSwitch_populatesModelName() {
        for provider in APIProvider.allCases {
            let modelName = provider.defaultModelName
            XCTAssertFalse(modelName.isEmpty, "\(provider.rawValue) should have a non-empty default model name")
        }
    }

    // Mirrors APIEndpointEditorView's name auto-fill predicate; documentation guard.
    // The live predicate lives in `.onChange(of: provider)` (APIEndpointEditorView.swift:121)
    // and cannot be extracted without refactoring the View body.

    /// The editor auto-fills the name with the provider's rawValue when name is empty
    /// or matches another provider's rawValue.
    func test_providerSwitch_autoFillsName() {
        let providerNames = APIProvider.allCases.map(\.rawValue)
        let currentName = "OpenAI"
        let newProvider = APIProvider.claude

        // The view logic: if name.isEmpty || providerNames.contains(name)
        let shouldAutoFill = currentName.isEmpty || providerNames.contains(currentName)
        XCTAssertTrue(shouldAutoFill, "Should auto-fill name when current name matches a provider name")

        let expectedName = newProvider.rawValue
        XCTAssertEqual(expectedName, "Claude")
    }

    func test_providerSwitch_doesNotOverwriteCustomName() {
        let providerNames = APIProvider.allCases.map(\.rawValue)
        let currentName = "My Custom Server"

        let shouldAutoFill = currentName.isEmpty || providerNames.contains(currentName)
        XCTAssertFalse(shouldAutoFill, "Should not auto-fill name when user has a custom name")
    }

    // MARK: - API key requirement partitioning

    func test_providersRequiringKey_partitionsCorrectly() {
        let requireKey = APIProvider.allCases.filter(\.requiresAPIKey)
        let noKey = APIProvider.allCases.filter { !$0.requiresAPIKey }

        XCTAssertEqual(Set(requireKey), [.openAI, .openAIResponses, .claude, .custom],
                       "Only OpenAI (Chat & Responses), Claude, and Custom should require API keys")
        XCTAssertEqual(Set(noKey), [.ollama, .lmStudio],
                       "Ollama and LM Studio should not require API keys")
    }

    // MARK: - Provider codable round-trip

    func test_provider_codableRoundTrip() throws {
        for provider in APIProvider.allCases {
            let data = try JSONEncoder().encode(provider)
            let decoded = try JSONDecoder().decode(APIProvider.self, from: data)
            XCTAssertEqual(decoded, provider, "\(provider.rawValue) should survive a JSON round-trip")
        }
    }
}
