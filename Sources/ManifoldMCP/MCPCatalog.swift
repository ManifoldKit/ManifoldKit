import Foundation
import ManifoldInference

#if MCPBuiltinCatalog

// MARK: - Static server spec

/// Holds all per-server static data in one place so each server is defined
/// exactly once instead of repeating the same strings across three overloads.
private struct MCPServerSpec {
    let id: UUID
    let displayName: String
    let endpointHost: String
    let endpointPath: String
    let toolNamespace: String
    let oauthScopes: [String]
    let oauthIssuerHost: String
    let dataDisclosure: String
}

// MARK: - Built-in specs
// UUID(uuidString:)! on a hardcoded literal is intentional: a typo should
// crash immediately at first access rather than silently producing a nil ID.

private let notionSpec = MCPServerSpec(
    id: UUID(uuidString: "5E4A6401-C86D-43DE-847E-AE02A34E89D8")!,
    displayName: "Notion",
    endpointHost: "mcp.notion.com",
    endpointPath: "/mcp",
    toolNamespace: "notion",
    oauthScopes: ["read:content", "write:content"],
    oauthIssuerHost: "notion.com",
    dataDisclosure: "Tool calls may send prompt content and selected arguments to Notion."
)

private let linearSpec = MCPServerSpec(
    id: UUID(uuidString: "B146A315-DFA4-4F75-9AF8-7B98CDE569FB")!,
    displayName: "Linear",
    endpointHost: "mcp.linear.app",
    endpointPath: "/mcp",
    toolNamespace: "linear",
    oauthScopes: ["read", "write"],
    oauthIssuerHost: "linear.app",
    dataDisclosure: "Tool calls may send prompt content and selected arguments to Linear."
)

private let githubSpec = MCPServerSpec(
    id: UUID(uuidString: "7B573A8A-C3CB-450D-9EBE-2E7D4C973682")!,
    displayName: "GitHub",
    endpointHost: "api.githubcopilot.com",
    endpointPath: "/mcp/",
    toolNamespace: "github",
    oauthScopes: ["read:user", "repo"],
    oauthIssuerHost: "github.com",
    dataDisclosure: "Tool calls may send prompt content and selected arguments to GitHub."
)

// MARK: - Catalog

public enum MCPCatalog {

    // MARK: All servers

    public static var all: [MCPServerDescriptor] {
        [notion, linear, github]
    }

    public static func all(oauthRedirectBaseURL: URL) throws -> [MCPServerDescriptor] {
        [
            try notion(oauthRedirectBaseURL: oauthRedirectBaseURL),
            try linear(oauthRedirectBaseURL: oauthRedirectBaseURL),
            try github(oauthRedirectBaseURL: oauthRedirectBaseURL),
        ]
    }

    // MARK: Notion

    public static var notion: MCPServerDescriptor {
        // URLComponents with hardcoded scheme/host/path always succeeds; try! is safe.
        try! makeDescriptor(from: notionSpec, redirectURI: defaultRedirectURI(toolNamespace: notionSpec.toolNamespace))
    }

    public static func notion(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try makeDescriptor(
            from: notionSpec,
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: notionSpec.toolNamespace,
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    // MARK: Linear

    public static var linear: MCPServerDescriptor {
        // URLComponents with hardcoded scheme/host/path always succeeds; try! is safe.
        try! makeDescriptor(from: linearSpec, redirectURI: defaultRedirectURI(toolNamespace: linearSpec.toolNamespace))
    }

    public static func linear(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try makeDescriptor(
            from: linearSpec,
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: linearSpec.toolNamespace,
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    // MARK: GitHub

    public static var github: MCPServerDescriptor {
        // URLComponents with hardcoded scheme/host/path always succeeds; try! is safe.
        try! makeDescriptor(from: githubSpec, redirectURI: defaultRedirectURI(toolNamespace: githubSpec.toolNamespace))
    }

    public static func github(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try makeDescriptor(
            from: githubSpec,
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: githubSpec.toolNamespace,
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    // MARK: - Descriptor factory

    private static func makeDescriptor(from spec: MCPServerSpec, redirectURI: URL) throws -> MCPServerDescriptor {
        var endpointComponents = URLComponents()
        endpointComponents.scheme = "https"
        endpointComponents.host = spec.endpointHost
        endpointComponents.path = spec.endpointPath

        guard let endpointURL = endpointComponents.url else {
            throw MCPError.malformedMetadata("Could not construct endpoint URL for \(spec.displayName)")
        }

        var issuerComponents = URLComponents()
        issuerComponents.scheme = "https"
        issuerComponents.host = spec.oauthIssuerHost

        guard let issuerURL = issuerComponents.url else {
            throw MCPError.malformedMetadata("Could not construct OAuth issuer URL for \(spec.displayName)")
        }

        return MCPServerDescriptor(
            id: spec.id,
            displayName: spec.displayName,
            transport: .streamableHTTP(endpoint: endpointURL, headers: [:]),
            authorization: .oauth(.init(
                clientName: "ManifoldKit",
                scopes: spec.oauthScopes,
                redirectURI: redirectURI,
                authorizationServerIssuer: issuerURL
            )),
            toolNamespace: spec.toolNamespace,
            resourceURL: endpointURL,
            dataDisclosure: spec.dataDisclosure
        )
    }

    // MARK: - Redirect URI helpers

    private static func defaultRedirectURI(toolNamespace: String) -> URL {
        var redirect = URLComponents()
        redirect.scheme = "basechat"
        redirect.host = "oauth"
        redirect.path = "/mcp/\(toolNamespace)/callback"
        // basechat:// custom-scheme URLComponents always resolves; this is safe.
        return redirect.url!
    }

    private static func universalLinkRedirectURI(
        toolNamespace: String,
        oauthRedirectBaseURL: URL?
    ) throws -> URL {
        guard let oauthRedirectBaseURL else {
            return defaultRedirectURI(toolNamespace: toolNamespace)
        }

        guard oauthRedirectBaseURL.scheme == "https",
              oauthRedirectBaseURL.host?.isEmpty == false,
              var redirect = URLComponents(
                url: oauthRedirectBaseURL,
                resolvingAgainstBaseURL: false
              ) else {
            throw MCPError.malformedMetadata("OAuth Universal Link redirect base URL must be absolute HTTPS")
        }

        let basePath = redirect.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = ([basePath, "mcp", toolNamespace, "callback"])
            .filter { $0.isEmpty == false }
        redirect.path = "/" + pathComponents.joined(separator: "/")
        redirect.query = nil
        redirect.fragment = nil
        guard let url = redirect.url else {
            throw MCPError.malformedMetadata("OAuth Universal Link redirect base URL could not be normalized")
        }
        return url
    }
}
#endif
