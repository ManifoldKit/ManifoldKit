# Bridging MCP tools to ToolRegistry

``MCPToolSource`` is the bridge from remote MCP tools to `ManifoldInference`'s `ToolRegistry`.

## Registration lifecycle

```swift,no-build
import ManifoldInference

let registry = ToolRegistry()
let source = try await MCPClient().connect(descriptor)

await source.register(in: registry)
// ... tools available to inference
await source.unregister(from: registry)
```

`register(in:)` will lazily fetch tools if needed, then register executors. `unregister(from:)` removes only names this source registered.

## Name shaping and filtering

During `refreshTools()`:

1. parse `tools/list`
2. apply ``MCPToolFilter`` (`allowAll`, allow list, deny list, max count)
3. apply namespace prefix (`docs.search`)
4. reject post-namespace duplicates
5. update all registries already registered with this source

## Approval behavior

Each bridged tool is an ``MCPToolExecutor`` with `requiresApproval` derived from ``MCPApprovalPolicy``.

Use:

```swift,no-build
await source.markApproved(toolName: "docs.search")
await source.invalidateApprovals(toolName: "docs.search")
```

## Error mapping

`MCPToolExecutor` maps transport/protocol errors into `ToolResult.ErrorKind` (`timeout`, `permissionDenied`, `transient`, etc.) and sanitizes control characters in tool output before returning content.
