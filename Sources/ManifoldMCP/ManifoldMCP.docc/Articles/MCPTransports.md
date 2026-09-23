# MCP transports

`ManifoldMCP` models transport via ``MCPTransportKind``.

## Streamable HTTP (supported)

Use `streamableHTTP` for SSE + request/response MCP sessions:

```swift,no-build
let descriptor = MCPServerDescriptor(
    displayName: "Docs",
    transport: .streamableHTTP(
        endpoint: URL(string: "https://mcp.docs.example.com/v1/sse")!,
        headers: ["X-Client": "ManifoldKit"]
    ),
    dataDisclosure: "Tool calls may send prompt content to Docs."
)
```

`MCPClient` uses ``MCPClientConfiguration`` limits for:

- SSE buffering and reconnect behavior (`sseStreamLimits`)
- per-request timeout (`requestTimeout`)
- max request concurrency
- message size and JSON nesting depth

## stdio (macOS only, non-Catalyst)

`MCPTransportKind.stdio` is connectable on macOS (excluding Mac Catalyst) and unavailable on other platforms.

`MCPClient` launches stdio servers with an argv-only subprocess policy:

- JSON-RPC messages use one UTF-8 JSON document per newline on stdin/stdout
- shell executables are rejected
- inherited environment variables are scrubbed to a fixed allowlist
- explicit `MCPStdioCommand.environment` entries are validated and overlaid
- shutdown is deterministic (`terminate` with bounded wait, then `SIGKILL` fallback)

When the child closes stdout or sends malformed output, the client removes its
tool source and emits a terminal connection event. A failed or cancelled
initialization closes the child before `connect` returns.

Local servers that used the former `Content-Length` stdio framing must emit and
accept newline-delimited JSON-RPC instead. This change does not affect HTTP
`Content-Length` headers.
