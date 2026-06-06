import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 7.
///
/// Adds `kindRaw` and `citationsJSON` columns to ``ChatMessage``.
/// Existing rows default to `kindRaw = "chat"` and `citationsJSON = nil`
/// via a lightweight migration — no data is touched.
///
/// All prior model types (session, sampler preset, API endpoint, benchmark
/// cache, RAG document, usage record) are carried forward unchanged.
public enum ManifoldSchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ManifoldSchemaV4.ChatSession.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageModel.self,
        ]
    }

    // MARK: - ChatMessage (V7 — adds kindRaw and citationsJSON)

    /// A single message in a chat conversation, persisted via SwiftData.
    ///
    /// Extends ``ManifoldSchemaV4/ChatMessage`` with:
    /// - `kindRaw`: raw storage for ``MessageKind`` (defaults to `"chat"`)
    /// - `citationsJSON`: JSON-encoded `[Citation]` array (nil when not RAG-augmented)
    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var timestamp: Date
        public var sessionID: UUID

        /// Plain-text cache of the message content.
        public var content: String

        /// JSON-encoded `[MessagePart]` array. This is the source of truth for
        /// structured content.
        public var contentPartsJSON: String

        /// Tokens used in the prompt for this response (cloud API backends only).
        public var promptTokens: Int?
        /// Tokens generated in this response (cloud API backends only).
        public var completionTokens: Int?

        /// Raw storage for ``MessageKind``. Defaults to "chat" so rows written
        /// before SchemaV7 decode as ``MessageKind/chat``.
        public var kindRaw: String = "chat"

        /// JSON-encoded ``[Citation]`` array. `nil` when the turn was not RAG-augmented.
        /// Moved from transient in SchemaV7.
        public var citationsJSON: String?

        public init(
            role: MessageRole,
            content: String,
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.content = content
            self.contentPartsJSON = Self.encode([.text(content)])
            self.kindRaw = "chat"
        }

        /// Creates a message from structured content parts.
        public init(
            role: MessageRole,
            contentParts: [MessagePart],
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.contentPartsJSON = Self.encode(contentParts)
            self.content = contentParts.compactMap(\.textContent).joined()
            self.kindRaw = "chat"
        }

        // MARK: - Content Parts

        /// The structured content parts of this message.
        public var contentParts: [MessagePart] {
            get { Self.decode(contentPartsJSON) }
            set {
                contentPartsJSON = Self.encode(newValue)
                content = newValue.compactMap(\.textContent).joined()
            }
        }

        // MARK: - Kind (MessageKind)

        public var kind: MessageKind {
            get { MessageKind(rawStorage: kindRaw) ?? .chat }
            set { kindRaw = newValue.rawStorage }
        }

        // MARK: - Citations

        public var citations: [Citation]? {
            get {
                guard let data = citationsJSON?.data(using: .utf8) else { return nil }
                do {
                    return try JSONDecoder().decode([Citation].self, from: data)
                } catch {
                    Log.persistence.warning("Failed to decode citationsJSON: \(error)")
                    return nil
                }
            }
            set {
                guard let v = newValue, !v.isEmpty else { citationsJSON = nil; return }
                do {
                    let data = try JSONEncoder().encode(v)
                    citationsJSON = String(data: data, encoding: .utf8)
                } catch {
                    Log.persistence.warning("Failed to encode citations: \(error)")
                    citationsJSON = nil
                }
            }
        }

        // MARK: - JSON Helpers (mirrors ManifoldSchemaV4.ChatMessage)

        static func encode(_ parts: [MessagePart]) -> String {
            do {
                let data = try JSONEncoder().encode(parts)
                if let json = String(data: data, encoding: .utf8) {
                    return json
                }
                Log.persistence.warning("Failed to convert encoded MessagePart data to UTF-8 string")
            } catch {
                Log.persistence.error("Failed to encode MessagePart array: \(error)")
            }
            return "[]"
        }

        static func decode(_ json: String) -> [MessagePart] {
            guard let data = json.data(using: .utf8) else {
                Log.persistence.warning("contentPartsJSON is not valid UTF-8")
                return json.isEmpty ? [] : [.text(json)]
            }
            do {
                return try JSONDecoder().decode([MessagePart].self, from: data)
            } catch {
                Log.persistence.warning("Failed to decode contentPartsJSON, falling back to text: \(error)")
                return json.isEmpty ? [] : [.text(json)]
            }
        }
    }
}

