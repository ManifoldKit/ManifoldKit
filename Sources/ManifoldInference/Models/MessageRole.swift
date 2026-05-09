/// The role of a participant in a chat conversation.
public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}
