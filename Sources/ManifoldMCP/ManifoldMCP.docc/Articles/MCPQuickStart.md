# MCP Quick Start (5 minutes)

Get a remote MCP server running in your `ToolRegistry` with explicit consent copy and tool boundaries.

> Important: Enable the `MCP` trait in your package dependency first. See
> <doc:MCPGettingStarted> for the dependency snippet.

## 1) Create a descriptor

```swift,no-build
import ManifoldMCP

let descriptor = MCPServerDescriptor(
    displayName: "Notion",
    transport: .streamableHTTP(
        endpoint: URL(string: "https://mcp.notion.com/v1/sse")!,
        headers: [:]
    ),
    authorization: .none,
    toolNamespace: "notion",
    resourceURL: URL(string: "https://mcp.notion.com/v1/sse"),
    dataDisclosure: "Tool calls may send selected prompt content to Notion.",
    toolFilter: .init(mode: .allowList, names: ["search", "pages.read"])
)
```

## 2) Connect and register

```swift,no-build
import ManifoldInference

let client = MCPClient()
let source = try await client.connect(descriptor)

let registry = ToolRegistry()
await source.register(in: registry)
```

Tools are listed from `tools/list`, filtered by ``MCPToolFilter``, then namespaced before registration.

## 3) Keep runtime boundaries explicit

```swift,no-build
await source.unregister(from: registry)
await client.disconnect(serverID: descriptor.id)
```

If the server emits `notifications/tools/list_changed`, refresh and re-register:

```swift,no-build
try await source.refreshTools()
```

## Built-in templates

Built-in catalog entries (`MCPCatalog.notion`, `.linear`, `.github`) are always available — the `MCPBuiltinCatalog` trait was retired in v0.48. Start from ``MCPCatalog``:

```swift,no-build
var notion = MCPCatalog.notion
notion = MCPServerDescriptor(
    id: notion.id,
    displayName: notion.displayName,
    transport: notion.transport,
    authorization: notion.authorization,
    toolNamespace: "notion-team-a",
    resourceURL: notion.resourceURL,
    dataDisclosure: notion.dataDisclosure,
    toolFilter: .init(mode: .allowList, names: ["search"])
)
```
