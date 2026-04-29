import BaseChatInference
import Foundation

#if AnyLanguageModel
import AnyLanguageModel

public struct AnyLanguageModelDescriptor: Sendable {
    public let model: any LanguageModel
    public let capabilities: BackendCapabilities

    public init(model: any LanguageModel, capabilities: BackendCapabilities) {
        self.model = model
        self.capabilities = capabilities
    }
}

public typealias AnyLanguageModelResolver = @Sendable (URL) throws -> AnyLanguageModelDescriptor

public enum AnyLanguageModelBridgeCapabilities {
    public static func remote(
        maxContextTokens: Int32 = 131_072,
        maxOutputTokens: Int = 8_192,
        supportsSystemPrompt: Bool = true
    ) -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: maxContextTokens,
            requiresPromptTemplate: false,
            supportsSystemPrompt: supportsSystemPrompt,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: maxOutputTokens,
            supportsStreaming: true,
            isRemote: true,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: false,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false
        )
    }
}

public enum AnyLanguageModelURLResolver {
    public static func resolve(_ url: URL) throws -> AnyLanguageModelDescriptor {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (url.scheme ?? "").lowercased()
        let queryItems = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })

        switch scheme {
        case "openai", "openai-responses":
            let model = try requireModelIdentifier(url, provider: scheme)
            let apiKey = try requireQueryItem("apiKey", in: queryItems, provider: scheme)
            let baseURL = URL(string: queryItems["baseURL"] ?? "") ?? OpenAILanguageModel.defaultBaseURL
            let variant: OpenAILanguageModel.APIVariant = scheme == "openai-responses" || queryItems["variant"] == "responses"
                ? .responses
                : .chatCompletions
            return AnyLanguageModelDescriptor(
                model: OpenAILanguageModel(baseURL: baseURL, apiKey: apiKey, model: model, apiVariant: variant),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        case "anthropic":
            let model = try requireModelIdentifier(url, provider: scheme)
            let apiKey = try requireQueryItem("apiKey", in: queryItems, provider: scheme)
            let baseURL = URL(string: queryItems["baseURL"] ?? "") ?? AnthropicLanguageModel.defaultBaseURL
            let apiVersion = queryItems["apiVersion"] ?? AnthropicLanguageModel.defaultAPIVersion
            let betas = queryItems["betas"]?.split(separator: ",").map { String($0) }
            return AnyLanguageModelDescriptor(
                model: AnthropicLanguageModel(baseURL: baseURL, apiKey: apiKey, apiVersion: apiVersion, betas: betas, model: model),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        case "gemini":
            let model = try requireModelIdentifier(url, provider: scheme)
            let apiKey = try requireQueryItem("apiKey", in: queryItems, provider: scheme)
            let baseURL = URL(string: queryItems["baseURL"] ?? "") ?? GeminiLanguageModel.defaultBaseURL
            let apiVersion = queryItems["apiVersion"] ?? GeminiLanguageModel.defaultAPIVersion
            return AnyLanguageModelDescriptor(
                model: GeminiLanguageModel(baseURL: baseURL, apiKey: apiKey, apiVersion: apiVersion, model: model),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        case "ollama":
            let model = try requireModelIdentifier(url, provider: scheme)
            let baseURL = URL(string: queryItems["baseURL"] ?? "") ?? OllamaLanguageModel.defaultBaseURL
            return AnyLanguageModelDescriptor(
                model: OllamaLanguageModel(baseURL: baseURL, model: model),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        case "openresponses":
            let model = try requireModelIdentifier(url, provider: scheme)
            let apiKey = try requireQueryItem("apiKey", in: queryItems, provider: scheme)
            let baseURL = URL(string: queryItems["baseURL"] ?? "")
                ?? URL(string: "https://openrouter.ai/api/v1/")!
            return AnyLanguageModelDescriptor(
                model: OpenResponsesLanguageModel(baseURL: baseURL, apiKey: apiKey, model: model),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        default:
            throw AnyLanguageModelBridgeError.unsupportedURLScheme(url)
        }
    }

    private static func requireQueryItem(_ name: String, in queryItems: [String: String], provider: String) throws -> String {
        guard let value = queryItems[name], !value.isEmpty else {
            throw AnyLanguageModelBridgeError.missingQueryItem(name: name, provider: provider)
        }
        return value
    }

    private static func requireModelIdentifier(_ url: URL, provider: String) throws -> String {
        let host = url.host(percentEncoded: false) ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let identifier: String
        switch (host.isEmpty, path.isEmpty) {
        case (false, true):
            identifier = host
        case (true, false):
            identifier = path
        case (false, false):
            identifier = [host, path].joined(separator: "/")
        default:
            throw AnyLanguageModelBridgeError.missingModelIdentifier(provider: provider)
        }
        return identifier.removingPercentEncoding ?? identifier
    }
}

public enum AnyLanguageModelBridgeError: LocalizedError {
    case unsupportedURLScheme(URL)
    case missingModelIdentifier(provider: String)
    case missingQueryItem(name: String, provider: String)
    case modelNotLoaded
    case unsupportedToolCalling
    case unsupportedStructuredOutput

    public var errorDescription: String? {
        switch self {
        case .unsupportedURLScheme(let url):
            return "Unsupported AnyLanguageModel URL scheme: \(url.scheme ?? "<missing>")."
        case .missingModelIdentifier(let provider):
            return "Missing model identifier for AnyLanguageModel provider '\(provider)'."
        case .missingQueryItem(let name, let provider):
            return "Missing required query item '\(name)' for AnyLanguageModel provider '\(provider)'."
        case .modelNotLoaded:
            return "No AnyLanguageModel descriptor is loaded."
        case .unsupportedToolCalling:
            return "The AnyLanguageModel bridge does not translate BaseChatKit tool definitions yet."
        case .unsupportedStructuredOutput:
            return "The AnyLanguageModel bridge currently streams plain text only; JSON mode is unavailable."
        }
    }
}
#endif
