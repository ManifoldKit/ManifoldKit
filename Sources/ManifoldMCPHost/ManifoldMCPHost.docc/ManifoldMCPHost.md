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

## Experimental tier

`ManifoldMCPHost` is in ManifoldKit's **experimental tier** (declared
2026-07-13) — it may break in any minor release, always migration-noted,
until it graduates. Graduation requires a real adopter: a shipping app or
companion that pins ManifoldKit and imports this module from non-test code.
Documentation and examples don't count as adoption. See
[docs/API-DESIGN.md § 7b](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md)
for the full policy.

## Topics

### Articles

- <doc:MCPHostServer>

### Server

- ``ManifoldMCPHost``
- ``ManifoldMCPHost/run(transport:)``
