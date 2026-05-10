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
    public let dataDisclosure: String
    public let toolFilter: MCPToolFilter
    public let approvalPolicy: MCPApprovalPolicy

    public init(
        id: UUID = UUID(),
        displayName: String,
        transport: MCPTransportKind,
        authorization: MCPAuthorizationDescriptor = .none,
        toolNamespace: String? = nil,
        resourceURL: URL? = nil,
        initializationTimeout: Duration = .seconds(30),
        dataDisclosure: String,
        toolFilter: MCPToolFilter = .allowAll,
        approvalPolicy: MCPApprovalPolicy = .perCall
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.authorization = authorization
        self.toolNamespace = toolNamespace
        self.resourceURL = resourceURL
        self.initializationTimeout = initializationTimeout
        self.dataDisclosure = dataDisclosure
        self.toolFilter = toolFilter
        self.approvalPolicy = approvalPolicy
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

    public init(
        sseStreamLimits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits,
        requestTimeout: Duration = .seconds(30),
        maxConcurrentRequestsPerSession: Int = 16,
        maxMessageBytes: Int = 4 * 1024 * 1024,
        maxJSONNestingDepth: Int = 32,
        keychain: MCPKeychainConfiguration = .init(),
        lifecyclePolicy: MCPSessionLifecyclePolicy = .cancelOnBackground,
        networkPathObserver: (any MCPNetworkPathObserver)? = nil,
        lifecycleObserver: (any MCPLifecycleEventObserver)? = MCPNotificationLifecycleEventObserver.platformMemoryWarnings()
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
