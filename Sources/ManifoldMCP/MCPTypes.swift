import Foundation
import Security
import ManifoldInference

public struct MCPServerDescriptor: Sendable, Equatable, Hashable, Codable {
    public let id: UUID
    public let displayName: String
    public let transport: MCPTransportKind
    public let authorization: MCPAuthorizationDescriptor
    public let toolNamespace: String?
    public let resourceURL: URL?
    public let initializationTimeout: Duration
    /// Per-server override for the request timeout used by `MCPSession`.
    /// When `nil`, the value from `MCPClientConfiguration.requestTimeout` is used.
    public var requestTimeout: Duration?
    public let dataDisclosure: String
    public let toolFilter: MCPToolFilter
    public let approvalPolicy: MCPApprovalPolicy

    /// STDIO transport launches a local subprocess. This expands the attack surface
    /// considerably compared with HTTP (no TLS, no SSRF guard, process-level privilege).
    /// Set to `true` only after auditing the subprocess binary and verifying it cannot
    /// be replaced by a less-privileged user. See `SECURITY.md §MCP Threat Model`.
    public var allowsSTDIOTransport: Bool

    /// MCP servers with no auth configuration send all tool call arguments in the
    /// clear and have no cryptographic identity. This is acceptable for fully
    /// local/loopback servers but is a significant risk for network-reachable ones.
    /// Set to `true` only after confirming the server is not reachable from untrusted
    /// networks. See `SECURITY.md §MCP Threat Model`.
    public var isUnauthenticatedUnsafe: Bool

    /// Opt-in for this server to issue `sampling/createMessage` requests back through
    /// the local engine. Default `false` — a server can spend inference budget on
    /// demand once this is `true`, so treat it like `allowsSTDIOTransport`: opt in per
    /// server, not globally. Sampling is only served when this is `true` AND
    /// `MCPClientConfiguration.samplingHandler` is set; otherwise every
    /// `sampling/createMessage` request gets a JSON-RPC "method not found" error and
    /// is never executed.
    ///
    /// `MCPServerDescriptor` is `Codable`, and a stored property's inline default does
    /// NOT make the compiler-synthesized `init(from:)` tolerate a missing key — Swift
    /// still hard-requires the key there. Decode tolerance for a persisted pre-#1925
    /// JSON blob missing this field comes from the custom `init(from:)` below (which
    /// uses `decodeIfPresent(...) ?? false`), not from this `= false`. The inline
    /// default here only covers memberwise construction. See #2284 review.
    public var allowsSampling: Bool = false

    /// Opt-in for this server to issue `elicitation/create` requests asking the user
    /// for structured input. Default `false` — mirrors `allowsSampling`'s per-server
    /// opt-in rationale: a server can prompt the user on demand once this is `true`,
    /// so treat it the same way. Elicitation is only served when this is `true` AND
    /// `MCPClientConfiguration.elicitationHandler` is set; otherwise every
    /// `elicitation/create` request gets a JSON-RPC "method not found" error and is
    /// never executed.
    ///
    /// See the note on `allowsSampling` above — decode tolerance for a persisted blob
    /// missing this key comes from the custom `init(from:)` below, not from this
    /// property-level default.
    public var allowsElicitation: Bool = false

    public init(
        id: UUID = UUID(),
        displayName: String,
        transport: MCPTransportKind,
        authorization: MCPAuthorizationDescriptor = .none,
        toolNamespace: String? = nil,
        resourceURL: URL? = nil,
        initializationTimeout: Duration = .seconds(30),
        requestTimeout: Duration? = nil,
        dataDisclosure: String,
        toolFilter: MCPToolFilter = .allowAll,
        approvalPolicy: MCPApprovalPolicy = .perCall,
        allowsSTDIOTransport: Bool = false,
        isUnauthenticatedUnsafe: Bool = false,
        allowsSampling: Bool = false,
        allowsElicitation: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.authorization = authorization
        self.toolNamespace = toolNamespace
        self.resourceURL = resourceURL
        self.initializationTimeout = initializationTimeout
        self.requestTimeout = requestTimeout
        self.dataDisclosure = dataDisclosure
        self.toolFilter = toolFilter
        self.approvalPolicy = approvalPolicy
        self.allowsSTDIOTransport = allowsSTDIOTransport
        self.isUnauthenticatedUnsafe = isUnauthenticatedUnsafe
        self.allowsSampling = allowsSampling
        self.allowsElicitation = allowsElicitation
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, transport, authorization, toolNamespace, resourceURL
        case initializationTimeout, requestTimeout, dataDisclosure, toolFilter, approvalPolicy
        case allowsSTDIOTransport, isUnauthenticatedUnsafe, allowsSampling, allowsElicitation
    }

    /// Hand-written to tolerate persisted JSON that predates `allowsSampling`
    /// (#1925/#2274) and/or `allowsElicitation` (#1926) — both decode via
    /// `decodeIfPresent(...) ?? false` rather than a hard-requiring `decode(...)`, so
    /// an older on-disk blob missing either key still decodes instead of throwing
    /// `DecodingError.keyNotFound`. `encode(to:)` stays compiler-synthesized (it needs
    /// no such tolerance) since providing only `init(from:)` here does not disable it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        transport = try container.decode(MCPTransportKind.self, forKey: .transport)
        authorization = try container.decode(MCPAuthorizationDescriptor.self, forKey: .authorization)
        toolNamespace = try container.decodeIfPresent(String.self, forKey: .toolNamespace)
        resourceURL = try container.decodeIfPresent(URL.self, forKey: .resourceURL)
        initializationTimeout = try container.decode(Duration.self, forKey: .initializationTimeout)
        requestTimeout = try container.decodeIfPresent(Duration.self, forKey: .requestTimeout)
        dataDisclosure = try container.decode(String.self, forKey: .dataDisclosure)
        toolFilter = try container.decode(MCPToolFilter.self, forKey: .toolFilter)
        approvalPolicy = try container.decode(MCPApprovalPolicy.self, forKey: .approvalPolicy)
        allowsSTDIOTransport = try container.decode(Bool.self, forKey: .allowsSTDIOTransport)
        isUnauthenticatedUnsafe = try container.decode(Bool.self, forKey: .isUnauthenticatedUnsafe)
        allowsSampling = try container.decodeIfPresent(Bool.self, forKey: .allowsSampling) ?? false
        allowsElicitation = try container.decodeIfPresent(Bool.self, forKey: .allowsElicitation) ?? false
    }
}

public enum MCPTransportKind: Sendable, Equatable, Hashable, Codable {
    case stdio(MCPStdioCommand)
    case streamableHTTP(endpoint: URL, headers: [String: String])
}

public struct MCPStdioCommand: Sendable, Equatable, Hashable, Codable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    /// Optional macOS Security Framework requirement string checked against the
    /// executable before launch. When `nil` the check is skipped. When non-nil,
    /// `SecStaticCodeCheckValidity` is called and the launch is aborted if the
    /// check fails. macOS-only; silently ignored on other platforms.
    public let codesignRequirement: String?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        codesignRequirement: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.codesignRequirement = codesignRequirement
    }

    public static func npx(package: String, args: [String] = []) -> Self {
        .init(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx", "-y", package] + args
        )
    }

    public static func executable(at url: URL, args: [String] = []) -> Self {
        .init(executable: url, arguments: args)
    }
}

public enum MCPAuthorizationDescriptor: Sendable, Equatable, Hashable, Codable {
    case none
    case oauth(OAuthDescriptor)

    public struct OAuthDescriptor: Sendable, Equatable, Hashable, Codable {
        public let clientName: String
        public let scopes: [String]
        public let redirectURI: URL
        public let authorizationServerIssuer: URL?
        public let softwareID: String?
        public let allowDynamicClientRegistration: Bool
        public let publicClient: Bool

        public init(
            clientName: String,
            scopes: [String],
            redirectURI: URL,
            authorizationServerIssuer: URL? = nil,
            softwareID: String? = nil,
            allowDynamicClientRegistration: Bool = true,
            publicClient: Bool = true
        ) {
            self.clientName = clientName
            self.scopes = scopes
            self.redirectURI = redirectURI
            self.authorizationServerIssuer = authorizationServerIssuer
            self.softwareID = softwareID
            self.allowDynamicClientRegistration = allowDynamicClientRegistration
            self.publicClient = publicClient
        }
    }
}

public struct MCPToolFilter: Sendable, Equatable, Hashable, Codable {
    public enum Mode: String, Sendable, Equatable, Hashable, Codable {
        case allowAll
        case allowList
        case denyList
    }

    public let mode: Mode
    public let names: [String]
    public let maxToolCount: Int

    public init(mode: Mode, names: [String] = [], maxToolCount: Int = 25) {
        self.mode = mode
        self.names = names
        self.maxToolCount = maxToolCount
    }

    public static var allowAll: Self { .init(mode: .allowAll) }

    /// Hard cap on the number of tools surfaced to Apple's Foundation Models
    /// backend. Apple's on-device tool surface degrades sharply once the tool
    /// list grows large — the model spends more of its context budget reciting
    /// schemas than reasoning. 16 is the empirically-derived ceiling used by
    /// ``MCPToolSource/foundationModelsEnabledNames(maxDepth:cap:)``.
    public static let foundationModelsToolCap: Int = 16
}

public struct MCPClientConfiguration: Sendable {
    public var sseStreamLimits: SSEStreamLimits
    public var requestTimeout: Duration
    public var maxConcurrentRequestsPerSession: Int
    public var maxMessageBytes: Int
    public var maxJSONNestingDepth: Int
    public var keychain: MCPKeychainConfiguration
    public var lifecyclePolicy: MCPSessionLifecyclePolicy
    public var networkPathObserver: (any MCPNetworkPathObserver)?
    public var lifecycleObserver: (any MCPLifecycleEventObserver)?

    /// Injected seam for server-initiated `sampling/createMessage` requests.
    /// `ManifoldMCP` never talks to `InferenceService` itself — this closure is the
    /// only bridge, and the host app owns everything that happens inside it.
    ///
    /// **Security requirement**: the host is responsible for user approval/consent
    /// and for rate-limiting or budgeting the inference spend this closure triggers.
    /// This closure is shared across every connected server, so `MCPSamplingRequest.serverID`
    /// (stamped by `MCPClient` from the connecting `MCPServerDescriptor.id`) is what
    /// lets a per-server approval/budget gate exist at all. `ManifoldMCP` does not
    /// gate calls into this closure beyond the per-server
    /// `MCPServerDescriptor.allowsSampling` opt-in — an app that sets this without its
    /// own approval and budget logic lets any connected, sampling-enabled MCP server
    /// spend inference budget on demand, with no consent prompt and no cap.
    ///
    /// `nil` (the default) means no server can use sampling regardless of
    /// `allowsSampling`; every `sampling/createMessage` request gets a JSON-RPC
    /// "method not found" error.
    public var samplingHandler: (@Sendable (MCPSamplingRequest) async throws -> MCPSamplingResult)?

    /// Injected seam for server-initiated `elicitation/create` requests — the server
    /// asks the user for structured input (a flat object of primitive-typed fields
    /// per the MCP spec) via a client-rendered form. `ManifoldMCP` is UI-free: it
    /// parses the request off the wire and hands it to this closure; the host app
    /// owns presenting the form and mapping the user's answer back to
    /// `MCPElicitationResult`. Note: this seam is UI-agnostic on purpose — the
    /// schema-driven SwiftUI form itself is a separate, later addition (tracked as a
    /// fast-follow), not part of `ManifoldMCP`.
    ///
    /// **Security requirement**: unlike sampling, this does not spend inference
    /// budget, but the returned content still flows to an untrusted server — the
    /// host's UI must make clear which server is asking and why, and must always
    /// offer `.decline`/`.cancel` as first-class options rather than only "submit".
    /// This closure is shared across every connected server, so `MCPElicitationRequest.serverID`
    /// (stamped by `MCPClient` from the connecting `MCPServerDescriptor.id`, never
    /// from server-controlled wire data) is the identity signal the host keys its UI
    /// on — without rendering it, a low-trust server can send a prompt
    /// indistinguishable from a trusted one (see #2284 review, blocker 1).
    /// `ManifoldMCP` does not gate calls into this closure beyond the per-server
    /// `MCPServerDescriptor.allowsElicitation` opt-in.
    ///
    /// `nil` (the default) means no server can use elicitation regardless of
    /// `allowsElicitation`; every `elicitation/create` request gets a JSON-RPC
    /// "method not found" error.
    public var elicitationHandler: (@Sendable (MCPElicitationRequest) async throws -> MCPElicitationResult)?

    public init(
        sseStreamLimits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits,
        requestTimeout: Duration = .seconds(30),
        maxConcurrentRequestsPerSession: Int = 16,
        maxMessageBytes: Int = 4 * 1024 * 1024,
        maxJSONNestingDepth: Int = 32,
        keychain: MCPKeychainConfiguration = .init(),
        lifecyclePolicy: MCPSessionLifecyclePolicy = .cancelOnBackground,
        networkPathObserver: (any MCPNetworkPathObserver)? = nil,
        lifecycleObserver: (any MCPLifecycleEventObserver)? = MCPNotificationLifecycleEventObserver.platformMemoryWarnings(),
        samplingHandler: (@Sendable (MCPSamplingRequest) async throws -> MCPSamplingResult)? = nil,
        elicitationHandler: (@Sendable (MCPElicitationRequest) async throws -> MCPElicitationResult)? = nil
    ) {
        self.sseStreamLimits = sseStreamLimits
        self.requestTimeout = requestTimeout
        self.maxConcurrentRequestsPerSession = maxConcurrentRequestsPerSession
        self.maxMessageBytes = maxMessageBytes
        self.maxJSONNestingDepth = maxJSONNestingDepth
        self.keychain = keychain
        self.lifecyclePolicy = lifecyclePolicy
        self.networkPathObserver = networkPathObserver
        self.lifecycleObserver = lifecycleObserver
        self.samplingHandler = samplingHandler
        self.elicitationHandler = elicitationHandler
    }
}

public struct MCPKeychainConfiguration: @unchecked Sendable {
    public let accessGroup: String?
    public let accessibility: CFString

    public init(
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }
}

public enum MCPSessionLifecyclePolicy: Sendable, Equatable, Hashable {
    case cancelOnBackground
    case detachAndResumeOnForeground
}

public enum MCPNetworkPathStatus: Sendable, Equatable, Hashable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

public protocol MCPNetworkPathObserver: Sendable {
    var pathUpdates: AsyncStream<MCPNetworkPathStatus> { get }
}

public enum MCPLifecycleEvent: Sendable, Equatable, Hashable {
    case didEnterBackground
    case willEnterForeground
    case memoryWarning
}

public protocol MCPLifecycleEventObserver: Sendable {
    var events: AsyncStream<MCPLifecycleEvent> { get }
}

public struct MCPCapabilities: Sendable, Equatable, Codable {
    public let protocolVersion: String
    public let serverName: String
    public let serverVersion: String
    public let supportsToolListChanged: Bool
    public let supportsResources: Bool
    public let supportsPrompts: Bool
    public let supportsLogging: Bool

    public init(
        protocolVersion: String = "2025-03-26",
        serverName: String = "",
        serverVersion: String = "",
        supportsToolListChanged: Bool = true,
        supportsResources: Bool = false,
        supportsPrompts: Bool = false,
        supportsLogging: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.supportsToolListChanged = supportsToolListChanged
        self.supportsResources = supportsResources
        self.supportsPrompts = supportsPrompts
        self.supportsLogging = supportsLogging
    }
}

public enum MCPConnectionEvent: Sendable {
    case connecting(serverID: UUID)
    case connected(serverID: UUID, capabilities: MCPCapabilities)
    case toolsChanged(serverID: UUID, addedNames: [String], removedNames: [String])
    case authorizationRequired(serverID: UUID, request: MCPAuthorizationRequest)
    case scopeDowngraded(serverID: UUID, requested: [String], granted: [String])
    case disconnected(serverID: UUID, reason: MCPDisconnectReason)
    case error(serverID: UUID, MCPError)
}

public enum MCPConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case reconnecting
    case failed
}

public enum MCPDisconnectReason: Sendable, Equatable, Hashable, Codable {
    case requested
    case transportClosed
    case networkUnavailable
    case memoryPressure
    case unauthorized
    case failed(String)
}

public enum MCPError: Error, Sendable, Equatable {
    case transportClosed
    case transportFailure(String)
    case protocolError(code: Int, message: String, data: String?)
    case requestTimeout
    case unsupportedProtocolVersion(server: String, client: String)
    case authorizationRequired(MCPAuthorizationRequest)
    case authorizationFailed(String)
    case dcrFailed(String)
    case malformedMetadata(String)
    case issuerMismatch(expected: URL, actual: URL)
    case ssrfBlocked(URL)
    case tooManyTools(Int)
    case toolNotFound(String)
    case oversizeContent(Int)
    case oversizeMessage(Int)
    case networkUnavailable
    case unauthorized
    case failed(String)
    case backgroundedDuringDispatch
    case cancelled
}

public struct MCPAuthorizationRequest: Sendable, Equatable {
    public let serverID: UUID
    public let resourceMetadataURL: URL?
    public let authorizationServerURL: URL?
    public let requiredScopes: [String]

    public init(
        serverID: UUID,
        resourceMetadataURL: URL? = nil,
        authorizationServerURL: URL? = nil,
        requiredScopes: [String] = []
    ) {
        self.serverID = serverID
        self.resourceMetadataURL = resourceMetadataURL
        self.authorizationServerURL = authorizationServerURL
        self.requiredScopes = requiredScopes
    }
}

public protocol MCPAuthorization: Sendable {
    func authorizationHeader(for requestURL: URL) async throws -> String?
    func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision
}

public enum AuthRetryDecision: Sendable {
    case retry
    case fail(MCPError)
}

public struct MCPNoAuthorization: MCPAuthorization {
    public init() {}

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        _ = requestURL
        return nil
    }

    public func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = statusCode
        _ = body
        return .fail(.authorizationFailed("unauthorized"))
    }
}

public enum MCPApprovalPolicy: Sendable, Equatable, Hashable, Codable {
    case perCall
    case perTurn
    case sessionForTool
    case sessionForServer
    case persistentForTool
}
