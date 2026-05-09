import Foundation
import ManifoldInference

#if MCPBuiltinCatalog
public enum MCPCatalog {
    public static var all: [MCPServerDescriptor] {
        [notion, linear, github]
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
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Notion."
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
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Linear."
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
            dataDisclosure: "Tool calls may send prompt content and selected arguments to GitHub."
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
        dataDisclosure: String
    ) -> MCPServerDescriptor {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = endpointHost
        endpoint.path = endpointPath

        var issuer = URLComponents()
        issuer.scheme = "https"
        issuer.host = oauthIssuerHost

        var redirect = URLComponents()
        redirect.scheme = "basechat"
        redirect.host = "oauth"
        redirect.path = "/mcp/\(toolNamespace)/callback"

        return MCPServerDescriptor(
            id: id,
            displayName: displayName,
            transport: .streamableHTTP(endpoint: endpoint.url!, headers: [:]),
            authorization: .oauth(.init(
                clientName: "ManifoldKit",
                scopes: oauthScopes,
                redirectURI: redirect.url!,
                authorizationServerIssuer: issuer.url!
            )),
            toolNamespace: toolNamespace,
            resourceURL: endpoint.url!,
            dataDisclosure: dataDisclosure
        )
    }
}
#endif
