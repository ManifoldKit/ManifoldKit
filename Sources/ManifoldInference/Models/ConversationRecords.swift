import Foundation

/// Plain-data snapshot of a chat session for use across persistence boundaries.
///
/// Decouples view models and inference orchestration from any specific storage
/// backend. The default implementation in `ManifoldCore` is
/// `SwiftDataPersistenceProvider`, but consumers can substitute any storage
/// layer that produces these records.
public struct ChatSessionRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var systemPrompt: String
    public var selectedModelID: UUID?
    public var selectedEndpointID: UUID?
    public var temperature: Float?
    public var topP: Float?
    public var repeatPenalty: Float?
    public var promptTemplate: PromptTemplate?
    public var contextSizeOverride: Int?
    public var pinnedMessageIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        systemPrompt: String = "",
        selectedModelID: UUID? = nil,
        selectedEndpointID: UUID? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        repeatPenalty: Float? = nil,
        promptTemplate: PromptTemplate? = nil,
        contextSizeOverride: Int? = nil,
        pinnedMessageIDs: Set<UUID> = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.systemPrompt = systemPrompt
        self.selectedModelID = selectedModelID
        self.selectedEndpointID = selectedEndpointID
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.promptTemplate = promptTemplate
        self.contextSizeOverride = contextSizeOverride
        self.pinnedMessageIDs = pinnedMessageIDs
    }
}

/// Plain-data snapshot of a chat message for use across persistence boundaries.
public struct ChatMessageRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var contentParts: [MessagePart]
    public var timestamp: Date
    public var sessionID: UUID
    public var promptTokens: Int?
    public var completionTokens: Int?

    /// Concatenated text parts for backward compatibility.
    ///
    /// Setting this replaces the entire `contentParts` array with a single `.text` part.
    public var content: String {
        get { contentParts.compactMap(\.textContent).joined() }
        set { contentParts = [.text(newValue)] }
    }

    /// True if the message contains non-empty visible text.
    /// Use instead of `content.isEmpty` to correctly handle thinking-only responses
    /// — a message with only `.thinking` parts (or only empty `.text("")` parts) returns false.
    public var hasVisibleContent: Bool {
        !content.isEmpty
    }

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        sessionID: UUID,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.contentParts = [.text(content)]
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// Creates a record from structured content parts.
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        contentParts: [MessagePart],
        timestamp: Date = Date(),
        sessionID: UUID,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.contentParts = contentParts
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

