# Getting Started with ManifoldMCP

Define one or more MCP server descriptors, then connect them through ``MCPClient``.

For a shortest-path setup, see <doc:MCPQuickStart>.

> Note: No trait is required — the `MCP` trait was retired in v0.48. Add the
> `ManifoldMCP` product to your target's dependencies and import it.
>
> ```swift
> .package(
>     url: "https://github.com/ManifoldKit/ManifoldKit.git",
>     from: "0.76.0" // x-release-please-version
> )
> ```

## 1) Create a descriptor

```swift,no-build
import ManifoldMCP

let descriptor = MCPServerDescriptor(
    displayName: "Internal Docs",
    transport: .streamableHTTP(
        endpoint: URL(string: "https://mcp.docs.example.com/v1/sse")!,
        headers: [:]
    ),
    authorization: .none,
    toolNamespace: "docs",
    dataDisclosure: "Tool calls may send selected prompt content to Internal Docs."
)
```

## 2) Connect the server

```swift,no-build
let client = MCPClient()
let source = try await client.connect(descriptor)
```

`MCPToolSource` lists, filters, namespaces, and executes MCP tools over the active session.

For deeper bridge behavior (refresh, approvals, error mapping), see <doc:MCPToolRegistryBridge>.

## 3) Register tools into your registry

```swift,no-build
let registry = ToolRegistry()
await source.register(in: registry)
```

When you disconnect, unregister the same source to keep tool visibility explicit:

```swift,no-build
await source.unregister(from: registry)
await client.disconnect(serverID: descriptor.id)
```

For OAuth-backed servers, wire ``MCPOAuthAuthorization`` as shown in <doc:MCPOAuthFlow>.
