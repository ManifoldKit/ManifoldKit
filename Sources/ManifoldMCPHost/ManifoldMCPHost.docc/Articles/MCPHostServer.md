# Exposing Your App as an MCP Server

Use ``ManifoldMCPHost`` to let external MCP clients — Claude Desktop, CI agents, or other tools — query your app's conversation history, RAG documents, and session management tools.

## Overview

ManifoldKit ships a full **client-side** MCP stack (`MCPClient`, `MCPToolSource`) that connects your app to external MCP servers. `ManifoldMCPHost` is the **server-side** counterpart: it listens for incoming JSON-RPC connections and exposes your app's live runtime state to any compliant MCP client.

The host is opt-in by design. It never starts unless you instantiate it and call ``ManifoldMCPHost/run(transport:)``.

## Setup

### 1. Instantiate ManifoldMCPHost

Provide the runtime ports your app already owns. `ConversationRuntime` and the two stores are required; `RAGService` is optional and enables the `search_documents` tool.

```swift,no-build
import ManifoldMCP
import ManifoldMCPHost
import ManifoldRuntime

// Assuming `bootstrap` is your ManifoldBootstrap instance:
let host = ManifoldMCPHost(
    sessionStore: bootstrap.sessionStore,
    messageStore: bootstrap.messageStore,
    conversationRuntime: bootstrap.conversationRuntime,
    ragService: bootstrap.ragService,      // optional
    serverName: "MyApp MCP Host"
)
```

### 2. Pick a transport

For local clients (Claude Desktop, scripts on the same machine), use the stdio transport:

```swift,no-build
#if os(macOS)
let transport = MCPHostStdioTransport()
#endif
```

HTTP/SSE server-side transport is not yet implemented. It is tracked in issue #874.

### 3. Start serving

`run(transport:)` blocks until the transport closes. Wrap it in a `Task` so your app continues running:

```swift,no-build
Task {
    do {
        try await host.run(transport: transport)
    } catch {
        Log.app.error("MCP host exited: \(error)")
    }
}
```

## Exposed resources and tools

### resources/list

Returns a flat list of all conversation sessions and, when a `RAGService` is wired up, all indexed documents. Each entry carries a stable `manifold://` URI.

| URI scheme | What it represents |
|---|---|
| `manifold://sessions/<uuid>` | A conversation session |
| `manifold://documents/<uuid>` | A RAG document |

### resources/read

Reads the content of a single resource:

- **Session** → returns all persisted messages in timestamp order (JSON).
- **Document** → returns metadata (title, fileType, chunkCount, sourceURL).

### tools/list + tools/call

| Tool | Input | What it does |
|---|---|---|
| `list_sessions` | none | Returns all sessions (id, title, updatedAt). |
| `send_message` | `session_id`, `text` | Sends a user message and returns the assistant reply. |
| `search_documents` | `query`, `limit` | Searches the RAG corpus; returns snippets. Present only when a `RAGService` is configured. |

## Claude Desktop configuration

Add an entry to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "myapp": {
      "command": "/path/to/MyApp.app/Contents/MacOS/MyApp",
      "args": ["--mcp-stdio"]
    }
  }
}
```

Your app should detect `--mcp-stdio` in its launch arguments and start the stdio transport instead of presenting its normal UI.

## Notes

- ``ManifoldMCPHost/run(transport:)`` processes one request at a time because `ManifoldMCPHost` is an `actor`. Concurrent clients require separate host instances (one per connection).
- `send_message` writes the generated reply into the session's persistent message store, exactly as if the user had typed the message in the app's UI. Use with care in production.
- `send_message` awaits the runtime's per-turn outcome instead of draining `ConversationRuntime.events`, so it can coexist with a UI event consumer.
