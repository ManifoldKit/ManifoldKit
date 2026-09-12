# Migrating MCP HTTP Authentication

**Audience:** consumer
**Status:** living

The pre-1.0 HTTP host initializer now requires a caller-supplied, per-launch bearer token:

```swift
import ManifoldMCPHost

func makeHTTPHost(perLaunchToken: String) throws -> MCPHostHTTPTransport {
    try MCPHostHTTPTransport(
        port: 8765,
        authorizationToken: perLaunchToken
    )
}
```

Configure the native MCP client to send the same value as `Authorization: Bearer <token>` on every GET, POST, and OPTIONS request. Generate the token with a cryptographically secure random source, keep it in memory, and never put it in a URL, log, repository file, or persistent configuration.

The HTTP host also validates the request `Host` as a loopback authority with the bound port and rejects every request carrying an `Origin` header. It no longer emits wildcard CORS headers. Browser clients must use a separate, host-owned authenticated gateway rather than connecting to ``MCPHostHTTPTransport`` directly.
