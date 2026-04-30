import Foundation
import BaseChatInference
import BaseChatRuntime
@preconcurrency import SwiftData

/// The current BaseChatKit SwiftData schema.
///
/// All model definitions live here. Previous schema versions (V1, V2) were
/// removed while the repo was still private — no users carry legacy data that
/// needs migration.
public enum BaseChatSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
            ModelBenchmarkCache.self,
        ]
    }

    // MARK: - ChatMessage

    /// A single message in a chat conversation, persisted via SwiftData.
    ///
    /// Content is stored as a JSON-encoded `[MessagePart]` array in
    /// `contentPartsJSON`. The `content` property concatenates text parts
    /// for backward compatibility.
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

        // MARK: - JSON Helpers

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

    // MARK: - ChatSession

    /// A chat session containing a sequence of messages with its own settings.
    ///
    /// Sessions hold per-session overrides for generation parameters. When an
    /// override is `nil`, the app falls back to global defaults from `SettingsService`.
    @Model
    public final class ChatSession {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date

        /// Per-session system prompt.
        public var systemPrompt: String

        /// The UUID of the selected ModelInfo for this session.
        public var selectedModelID: UUID?

        /// The UUID of the selected APIEndpoint for this session.
        public var selectedEndpointID: UUID?

        // Per-session generation overrides (nil = use global default)
        public var temperature: Float?
        public var topP: Float?
        public var repeatPenalty: Float?

        /// Stored as PromptTemplate.rawValue; nil means auto-detect or global default.
        public var promptTemplateRawValue: String?

        /// User override for context window size; nil uses model default.
        public var contextSizeOverride: Int?

        /// Comma-separated UUID strings of pinned messages in this session.
        /// nil means no messages are pinned.
        public var pinnedMessageIDsRaw: String?

        public init(title: String = "New Chat") {
            self.id = UUID()
            self.title = title
            self.createdAt = Date()
            self.updatedAt = Date()
            self.systemPrompt = ""
        }

        /// The set of pinned message IDs for this session.
        ///
        /// Pinned messages are preserved when history is trimmed to fit the context window, regardless of age.
        /// Serialized as comma-separated UUID strings in ``pinnedMessageIDsRaw``.
        public var pinnedMessageIDs: Set<UUID> {
            get {
                guard let raw = pinnedMessageIDsRaw else { return [] }
                return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            }
            set {
                pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
            }
        }

        /// Convenience to get/set the prompt template as a `PromptTemplate` enum.
        public var promptTemplate: PromptTemplate? {
            get {
                guard let raw = promptTemplateRawValue else { return nil }
                return PromptTemplate(rawValue: raw)
            }
            set {
                promptTemplateRawValue = newValue?.rawValue
            }
        }
    }

    // MARK: - SamplerPreset

    /// A saved set of generation parameters that can be applied to any session.
    @Model
    public final class SamplerPreset {
        public var id: UUID
        public var name: String
        public var temperature: Float
        public var topP: Float
        public var repeatPenalty: Float
        public var createdAt: Date

        public init(name: String, temperature: Float = 0.7, topP: Float = 0.9, repeatPenalty: Float = 1.1) {
            self.id = UUID()
            self.name = name
            self.temperature = temperature
            self.topP = topP
            self.repeatPenalty = repeatPenalty
            self.createdAt = Date()
        }
    }

    // MARK: - APIEndpoint

    /// A configured cloud API endpoint persisted via SwiftData.
    ///
    /// The API key is NOT stored here — it lives in the Keychain, referenced
    /// by this endpoint's `id` as the Keychain account identifier.
    @Model
    public final class APIEndpoint {
        public var id: UUID
        public var name: String
        public var providerRawValue: String
        public var baseURL: String
        public var modelName: String
        public var createdAt: Date
        public var isEnabled: Bool

        public init(
            name: String,
            provider: APIProvider,
            baseURL: String? = nil,
            modelName: String? = nil
        ) {
            self.id = UUID()
            self.name = name
            self.providerRawValue = provider.rawValue
            self.baseURL = baseURL ?? provider.defaultBaseURL
            self.modelName = modelName ?? provider.defaultModelName
            self.createdAt = Date()
            self.isEnabled = true
        }

        /// The provider type as an enum.
        public var provider: APIProvider {
            get { APIProvider(rawValue: providerRawValue) ?? .custom }
            set { providerRawValue = newValue.rawValue }
        }

        /// The Keychain account identifier for this endpoint's API key.
        public var keychainAccount: String {
            id.uuidString
        }

        /// Stores an API key in the Keychain for this endpoint.
        ///
        /// Throws `KeychainError.storeFailed` when the write is rejected
        /// (locked device, entitlement mismatch, corrupted item). Surface the
        /// error to the user — silently swallowing it leaves the impression
        /// that the key was saved when it wasn't.
        public func setAPIKey(_ key: String) throws {
            try KeychainService.store(key: key, account: keychainAccount)
        }

        /// Deletes the API key from the Keychain.
        ///
        /// Throws `KeychainError.deleteFailed` on Keychain errors. A missing
        /// item is not an error — callers can rely on this being idempotent.
        public func deleteAPIKey() throws {
            try KeychainService.delete(account: keychainAccount)
        }

        /// Validates the endpoint's URL structure and returns a typed result.
        ///
        /// This is a pure structural check — it does NOT verify whether an API key
        /// exists in the Keychain. Use `APIProvider.requiresAPIKey` and
        /// `KeychainService.retrieve(account: endpoint.keychainAccount)` separately
        /// to check credential readiness.
        ///
        /// Security: rejects URLs that would let a malicious endpoint config pivot
        /// into the user's LAN or cloud metadata services (SSRF). See
        /// ``APIEndpoint/classifyDisallowedPrivateHost(_:)`` for the blocked IP
        /// ranges. Only `http`/`https` schemes are accepted. Non-HTTPS is permitted
        /// only for the explicit loopback allowlist (`127.0.0.1`, `::1`, `localhost`).
        ///
        /// Returns `.success` when the URL is well-formed, uses a supported scheme,
        /// and does not target a reserved address class. Returns `.failure` with a
        /// specific ``APIEndpointValidationReason`` so the UI can explain *why* an
        /// endpoint is rejected instead of a generic label.
        public func validate() -> Result<Void, APIEndpointValidationReason> {
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .failure(.emptyURL)
            }

            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  url.host() != nil else {
                return .failure(.malformedURL)
            }

            // Only http/https are valid. Reject file, ftp, data, javascript, etc.
            guard scheme == "http" || scheme == "https" else {
                return .failure(.unsupportedScheme(scheme))
            }

            // Loopback dev servers (e.g. Ollama, LM Studio) are allowed over plain HTTP.
            if Self.isLocalhost(url) {
                return .success(())
            }

            // Non-loopback must be HTTPS.
            if scheme != "https" {
                return .failure(.insecureScheme)
            }

            // Block SSRF into LAN / cloud metadata even when HTTPS is used. A
            // cert-pinned private-range target is still a private-range target.
            if let reason = Self.classifyDisallowedPrivateHost(url) {
                return .failure(reason)
            }

            return .success(())
        }

        /// Structural validity of the endpoint URL.
        ///
        /// Derived from ``validate()`` — prefer `validate()` when you need the
        /// specific rejection reason to surface in UI.
        public var isValid: Bool {
            if case .success = validate() { return true }
            return false
        }

        /// Checks if the URL points to a local server.
        ///
        /// Delegates to ``PrivateIPClassifier/isLocalhostURL(_:)``. Only the three
        /// explicit loopback literals (`localhost`, `127.0.0.1`, `::1`) match —
        /// broader `127.x.x.x` and IPv4-mapped IPv6 loopback are excluded.
        static func isLocalhost(_ url: URL) -> Bool {
            PrivateIPClassifier.isLocalhostURL(url)
        }

        /// Classifies a URL's host as pointing at a private, link-local, or
        /// otherwise reserved IP range, returning the specific rejection reason
        /// (or `nil` if the host is acceptable).
        ///
        /// Only IP literals are inspected. DNS names are not resolved — validation
        /// is called synchronously from SwiftUI settings forms and must stay fast.
        /// DNS rebinding is mitigated at the request layer by
        /// `BaseChatBackends.DNSRebindingGuard`, which resolves hostnames and
        /// rejects connections to private/reserved addresses at connect time.
        ///
        /// Classification logic is shared with ``PrivateIPClassifier`` to ensure a
        /// single source of truth for blocked IP ranges across both validation layers.
        static func classifyDisallowedPrivateHost(_ url: URL) -> APIEndpointValidationReason? {
            guard let rawHost = url.host()?.lowercased() else { return nil }
            let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

            guard let category = PrivateIPClassifier.classifyIPLiteral(host) else {
                // DNS names pass through — request-layer guard handles them.
                return nil
            }

            switch category {
            case .privateHost:        return .privateHost
            case .linkLocalHost:      return .linkLocalHost
            case .ipv6UniqueLocal:    return .ipv6UniqueLocal
            case .ipv4MappedLoopback: return .ipv4MappedLoopback
            case .multicastReserved:  return .multicastReserved
            }
        }
    }

    // MARK: - ModelBenchmarkCache

    /// Persists a ``ModelBenchmarkResult`` keyed by the model's file name.
    ///
    /// SwiftData does not natively support storing enums or nested Codable structs
    /// as columns, so the result is decomposed into scalar fields. Use ``toResult()``
    /// to reconstitute a ``ModelBenchmarkResult`` value.
    @Model
    public final class ModelBenchmarkCache {

        /// The file name of the model this result belongs to (e.g. `"model.Q4_K_M.gguf"`).
        public var modelFileName: String

        /// Raw ``ModelCapabilityTier/rawValue`` for the stored tier.
        public var tierRaw: Int

        /// Measured tokens-per-second, or `nil` if not available.
        public var tokensPerSecond: Double?

        /// Peak memory usage in bytes, or `nil` if not available.
        public var memoryBytes: Int64?

        /// When the benchmark was performed.
        public var measuredAt: Date

        /// The capability tier stored in this cache entry.
        public var tier: ModelCapabilityTier {
            ModelCapabilityTier(rawValue: tierRaw) ?? .minimal
        }

        public init(modelFileName: String, result: ModelBenchmarkResult) {
            self.modelFileName = modelFileName
            self.tierRaw = result.tier.rawValue
            self.tokensPerSecond = result.tokensPerSecond
            self.memoryBytes = result.memoryBytes
            self.measuredAt = result.measuredAt
        }

        /// Reconstitutes a ``ModelBenchmarkResult`` from this cache entry.
        public func toResult() -> ModelBenchmarkResult {
            ModelBenchmarkResult(
                tier: tier,
                tokensPerSecond: tokensPerSecond,
                memoryBytes: memoryBytes,
                measuredAt: measuredAt
            )
        }
    }
}
