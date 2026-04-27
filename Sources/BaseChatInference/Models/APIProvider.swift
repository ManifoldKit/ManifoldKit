/// The cloud API provider type.
public enum APIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    /// OpenAI Responses API (`POST /v1/responses`).
    ///
    /// Distinguished from ``openAI`` (Chat Completions) because the wire
    /// formats are incompatible: Responses uses named SSE events and surfaces
    /// reasoning summaries as first-class deltas. Selecting this provider
    /// routes through ``OpenAIResponsesBackend`` and emits
    /// ``GenerationEvent/thinkingToken(_:)`` for the reasoning stream.
    case openAIResponses = "OpenAI Responses"
    case claude = "Claude"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Default base URL for this provider.
    public var defaultBaseURL: String {
        switch self {
        case .openAI, .openAIResponses: return "https://api.openai.com"
        case .claude: return "https://api.anthropic.com"
        case .ollama: return "http://localhost:11434"
        case .lmStudio: return "http://localhost:1234"
        case .custom: return "https://"
        }
    }

    /// Whether this provider requires an API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .openAIResponses, .claude, .custom: return true
        case .ollama, .lmStudio: return false
        }
    }

    /// Default model name for this provider.
    public var defaultModelName: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .openAIResponses: return "gpt-5"
        case .claude: return "claude-sonnet-4-6"
        case .ollama: return "llama3.2"
        case .lmStudio: return "local-model"
        case .custom: return "model"
        }
    }

    /// The providers actually available in this build.
    ///
    /// Iterates the cases compatible with the `Ollama` and `CloudSaaS` traits.
    /// Use this when a UI or registration loop should only present providers
    /// the build can actually instantiate. ``allCases`` stays unconditional —
    /// it's data, not behaviour, and `ConversationRecords.selectedEndpointID`
    /// must be able to decode any case regardless of build flavour.
    public static var availableInBuild: [APIProvider] {
        CompiledBackends.current.orderedCloudProviders
    }
}
