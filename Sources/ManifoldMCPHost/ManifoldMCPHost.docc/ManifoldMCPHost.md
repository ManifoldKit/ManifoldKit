# ``ManifoldMCPHost``

Expose your app as a Model Context Protocol **server** — let Claude Desktop, CI
agents, or other MCP clients query your live conversation history, RAG documents,
and session tools.

## Overview

ManifoldKit ships a full client-side MCP stack (`MCPClient`, `MCPToolSource`)
that connects your app *to* external servers. `ManifoldMCPHost` is the
server-side counterpart: an `actor` that listens for incoming JSON-RPC
connections and surfaces your app's runtime state — sessions, messages, and
optional RAG search — to any compliant MCP client.

The host is opt-in by design. It never starts unless you instantiate
``ManifoldMCPHost`` and call ``ManifoldMCPHost/run(transport:)``. See
<doc:MCPHostServer> for the end-to-end setup, the exposed resources and tools,
and Claude Desktop wiring.

## Topics

### Articles

- <doc:MCPHostServer>

### Server

- ``ManifoldMCPHost``
- ``ManifoldMCPHost/run(transport:)``
