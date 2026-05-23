# Built-in MCP Catalog

`MCPCatalog` is compiled only when the `MCPBuiltinCatalog` trait is enabled.

## Trait

```bash
swift test --filter ManifoldMCPTests --disable-default-traits --traits MCPBuiltinCatalog
```

## Purpose

The built-in catalog ships conservative defaults for common providers:

- `MCPCatalog.notion`
- `MCPCatalog.linear`
- `MCPCatalog.github`

Each descriptor includes:

- stable descriptor IDs for persistence/audit continuity
- HTTPS streamable endpoint defaults
- OAuth descriptor defaults
- explicit `dataDisclosure` copy for user-facing consent surfaces

Treat these as templates: apps can clone and override hostnames, scopes, timeouts, and tool filters to match deployment policy.

```swift,no-build
var github = MCPCatalog.github
github = MCPServerDescriptor(
    id: github.id,
    displayName: github.displayName,
    transport: github.transport,
    authorization: github.authorization,
    toolNamespace: "github-org-a",
    resourceURL: github.resourceURL,
    initializationTimeout: .seconds(10),
    dataDisclosure: github.dataDisclosure,
    toolFilter: .init(mode: .allowList, names: ["issues.list", "pull_request.get"])
)
```

## Endpoint Maintenance

Built-in catalog endpoints are verified against provider documentation. If a connection 404s or fails
authentication discovery, check the provider's MCP integration docs for the current canonical URL,
then file an issue or PR to update `MCPCatalog`.

| Provider | Last verified | Docs URL |
|---|---|---|
| Notion | 2026-04-26 | https://developers.notion.com |
| Linear | 2026-04-26 | https://linear.app/docs |
| GitHub | 2026-04-26 | https://docs.github.com/copilot |
