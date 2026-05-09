import Foundation
import ManifoldInference

#if MCPBuiltinCatalog
public enum MCPCatalog {
    public static var all: [MCPServerDescriptor] {
        [notion, linear, github]
    }

    public static func all(oauthRedirectBaseURL: URL) throws -> [MCPServerDescriptor] {
        [
            try notion(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL)),
            try linear(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL)),
            try github(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL)),
        ]
    }

    public static var notion: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "5E4A6401-C86D-43DE-847E-AE02A34E89D8")!,
            displayName: "Notion",
            endpointHost: "mcp.notion.com",
            endpointPath: "/mcp",
            toolNamespace: "notion",
            oauthScopes: ["read:content", "write:content"],
            oauthIssuerHost: "notion.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Notion.",
            redirectURI: defaultRedirectURI(toolNamespace: "notion")
        )
    }

    public static func notion(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try notion(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL))
    }

    private static func notion(oauthRedirectBaseURL: URL?) throws -> MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "5E4A6401-C86D-43DE-847E-AE02A34E89D8")!,
            displayName: "Notion",
            endpointHost: "mcp.notion.com",
            endpointPath: "/mcp",
            toolNamespace: "notion",
            oauthScopes: ["read:content", "write:content"],
            oauthIssuerHost: "notion.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Notion.",
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: "notion",
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    public static var linear: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "B146A315-DFA4-4F75-9AF8-7B98CDE569FB")!,
            displayName: "Linear",
            endpointHost: "mcp.linear.app",
            endpointPath: "/mcp",
            toolNamespace: "linear",
            oauthScopes: ["read", "write"],
            oauthIssuerHost: "linear.app",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Linear.",
            redirectURI: defaultRedirectURI(toolNamespace: "linear")
        )
    }

    public static func linear(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try linear(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL))
    }

    private static func linear(oauthRedirectBaseURL: URL?) throws -> MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "B146A315-DFA4-4F75-9AF8-7B98CDE569FB")!,
            displayName: "Linear",
            endpointHost: "mcp.linear.app",
            endpointPath: "/mcp",
            toolNamespace: "linear",
            oauthScopes: ["read", "write"],
            oauthIssuerHost: "linear.app",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Linear.",
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: "linear",
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    public static var github: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "7B573A8A-C3CB-450D-9EBE-2E7D4C973682")!,
            displayName: "GitHub",
            endpointHost: "api.githubcopilot.com",
            endpointPath: "/mcp/",
            toolNamespace: "github",
            oauthScopes: ["read:user", "repo"],
            oauthIssuerHost: "github.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to GitHub.",
            redirectURI: defaultRedirectURI(toolNamespace: "github")
        )
    }

    public static func github(oauthRedirectBaseURL: URL) throws -> MCPServerDescriptor {
        try github(oauthRedirectBaseURL: Optional(oauthRedirectBaseURL))
    }

    private static func github(oauthRedirectBaseURL: URL?) throws -> MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "7B573A8A-C3CB-450D-9EBE-2E7D4C973682")!,
            displayName: "GitHub",
            endpointHost: "api.githubcopilot.com",
            endpointPath: "/mcp/",
            toolNamespace: "github",
            oauthScopes: ["read:user", "repo"],
            oauthIssuerHost: "github.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to GitHub.",
            redirectURI: try universalLinkRedirectURI(
                toolNamespace: "github",
                oauthRedirectBaseURL: oauthRedirectBaseURL
            )
        )
    }

    private static func descriptor(
        id: UUID,
        displayName: String,
        endpointHost: String,
        endpointPath: String,
        toolNamespace: String,
        oauthScopes: [String],
        oauthIssuerHost: String,
        dataDisclosure: String,
        redirectURI: URL
    ) -> MCPServerDescriptor {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = endpointHost
        endpoint.path = endpointPath

        var issuer = URLComponents()
        issuer.scheme = "https"
        issuer.host = oauthIssuerHost

        return MCPServerDescriptor(
            id: id,
            displayName: displayName,
            transport: .streamableHTTP(endpoint: endpoint.url!, headers: [:]),
            authorization: .oauth(.init(
                clientName: "ManifoldKit",
                scopes: oauthScopes,
                redirectURI: redirectURI,
                authorizationServerIssuer: issuer.url!
            )),
            toolNamespace: toolNamespace,
            resourceURL: endpoint.url!,
            dataDisclosure: dataDisclosure
        )
    }

    private static func defaultRedirectURI(toolNamespace: String) -> URL {
        var redirect = URLComponents()
        redirect.scheme = "basechat"
        redirect.host = "oauth"
        redirect.path = "/mcp/\(toolNamespace)/callback"
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
