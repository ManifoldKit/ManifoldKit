# Provider Fixture Data

Recorded JSON-RPC responses for Notion, Linear, and GitHub MCP servers.
Used by `MCPProviderFixtureContractTests` for offline regression testing.

## Spec version

MCP protocol version: `2025-03-26`
Last recorded: 2026-04-26
Regeneration script: `scripts/regenerate-mcp-fixtures.sh`

## Endpoint verification

| Provider | Endpoint | Verified |
|---|---|---|
| Notion | https://mcp.notion.com/mcp | 2026-04-26 |
| Linear | https://mcp.linear.app/mcp | 2026-04-26 |
| GitHub | https://api.githubcopilot.com/mcp/ | 2026-04-26 |

## Files

Each provider directory contains:
- `server.json` — provider metadata, catalog descriptor snapshot
- `initialize.result.json` — response to `initialize` handshake
- `tools.list.result.json` — response to `tools/list`

To regenerate: `scripts/regenerate-mcp-fixtures.sh` (requires `npx` and network access to each provider's MCP endpoint).
