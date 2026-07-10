/// The cloud API provider type.
///
/// ## Raw values are a frozen persisted contract
///
/// Since Wave 2 (v0.68) the raw values are **stable opaque codes**
/// (`"openAI"`, `"openAIResponses"`, `"claude"`, `"ollama"`, `"lmStudio"`,
/// `"custom"`), not the human-readable display labels they used to be. They are
/// persisted in SwiftData (`ManifoldSchemaV3/V4.APIEndpoint.providerRawValue`)
/// and serialized in ``APIEndpointRecord``'s `Codable` wire form, so they may
/// **not** change again without a migration. Use ``displayName`` for anything
/// user-facing.
///
/// The enum stays **closed** deliberately: it is a wire-routing discriminant —
/// `CloudSaaSBackends` and friends switch exhaustively on it to pick a backend
/// class. An open value would route to no backend at all, which is strictly
/// worse than the `.custom` OpenAI-compatible fallback that third-party
/// providers (Gemini/xAI/Groq/…) already ride. Third parties register a
/// `CloudProviderDescriptor` with a reverse-DNS `providerID` and persist through
/// `.custom` rather than minting a new case here.
///
/// ## Legacy display-string migration
///
/// Builds before v0.68 persisted the *display* labels (`"OpenAI Responses"`,
/// `"LM Studio"`, …) as raw values. ``parse(_:)`` and the custom `Codable`
/// decode both accept those legacy strings so already-persisted data migrates
/// in place; encoding always writes the new stable code.
public enum APIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openAI"
    /// OpenAI Responses API (`POST /v1/responses`).
    ///
    /// Distinguished from ``openAI`` (Chat Completions) because the wire
    /// formats are incompatible: Responses uses named SSE events and surfaces
    /// reasoning summaries as first-class deltas. Selecting this provider
    /// routes through ``OpenAIResponsesBackend`` and emits
    /// ``GenerationEvent/thinkingToken(_:)`` for the reasoning stream.
    case openAIResponses = "openAIResponses"
    case claude = "claude"
    case ollama = "ollama"
    case lmStudio = "lmStudio"
    case custom = "custom"

    public var id: String { rawValue }

    /// Human-readable label for UI pickers, badges, and log lines.
    ///
    /// Carries the strings that used to be this enum's raw values. Always use
    /// this for anything a person reads; ``rawValue`` is the stable persisted
    /// code, not a display string.
    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .openAIResponses: return "OpenAI Responses"
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .custom: return "Custom"
        }
    }

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
    /// Since v0.48 the cloud families compile unconditionally, so this is
    /// every built-in provider (plus registry-registered third parties), in
    /// documented sort order. Kept as the single registration/UI iteration
    /// point: whether an endpoint is *configured* for a provider is a
    /// runtime question, answered by the endpoint store — not this list.
    public static var availableInBuild: [APIProvider] {
        CompiledBackends.current.orderedCloudProviders
    }

    // MARK: - Migration helper

    /// Parses a persisted / wire string into a provider, accepting **both** the
    /// stable v0.68+ codes (`"openAI"`, `"lmStudio"`, …) and the legacy pre-0.68
    /// display strings (`"OpenAI"`, `"LM Studio"`, …).
    ///
    /// Mirrors ``BackendName/parse(_:)``. Use it at every trust boundary that
    /// reads a provider string off disk or the wire that may pre-date the
    /// stable-code migration. Returns `nil` for strings that match neither form
    /// so callers can distinguish "a known provider" from an arbitrary string.
    public static func parse(_ string: String) -> APIProvider? {
        // Fast path: a stable code matches an enum raw value directly.
        if let provider = APIProvider(rawValue: string) {
            return provider
        }
        // Legacy pre-0.68 display-string fallbacks.
        switch string {
        case "OpenAI":           return .openAI
        case "OpenAI Responses": return .openAIResponses
        case "Claude":           return .claude
        case "Ollama":           return .ollama
        case "LM Studio":        return .lmStudio
        case "Custom":           return .custom
        default:                 return nil
        }
    }

    // MARK: - Codable (single-value string; decodes legacy display strings)

    /// Decodes via ``parse(_:)`` so JSON written by pre-0.68 builds (which
    /// persisted display strings) keeps decoding. Throws
    /// `DecodingError.dataCorrupted` for genuinely unknown strings rather than
    /// silently falling back — an unrecognised provider is a routing hazard.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let provider = APIProvider.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised APIProvider raw value \"\(raw)\"."
            )
        }
        self = provider
    }

    /// Encodes the stable opaque code (never the display string).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
