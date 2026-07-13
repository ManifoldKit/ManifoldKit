# ``ManifoldMCP``

Model Context Protocol (MCP) client primitives for ManifoldKit.

## Overview

`ManifoldMCP` provides the descriptor and client surface for attaching MCP servers to ``InferenceService`` tool execution. The module is intentionally split into:

- transport/auth/capability types (`MCPServerDescriptor`, `MCPTransportKind`, `MCPAuthorizationDescriptor`)
- connection + source lifecycle (`MCPClient`, `MCPToolSource`)
- catalog presets (`MCPCatalog`)

Use this module to model and audit tool boundaries before wiring concrete transport internals.

## Experimental tier

`ManifoldMCP` is in ManifoldKit's **experimental tier** (declared 2026-07-13) — it
may break in any minor release, always migration-noted, until it graduates.
Graduation requires a real adopter: a shipping app or companion that pins
ManifoldKit and imports this module from non-test code. Documentation and
examples don't count as adoption. See
[docs/API-DESIGN.md § 7b](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md)
for the full policy.

## Topics

### Articles

- <doc:MCPQuickStart>
- <doc:MCPGettingStarted>
- <doc:MCPTransports>
- <doc:MCPOAuthFlow>
- <doc:MCPSecurityModel>
- <doc:MCPToolRegistryBridge>
- <doc:MCPAppPrivacyChecklist>
- <doc:MCPCatalogBuiltin>

### Descriptors

- ``MCPServerDescriptor``
- ``MCPTransportKind``
- ``MCPStdioCommand``
- ``MCPAuthorizationDescriptor``
- ``MCPToolFilter``

### Connection and lifecycle

- ``MCPClient``
- ``MCPToolSource``
- ``MCPClientConfiguration``
- ``MCPKeychainConfiguration``
- ``MCPSessionLifecyclePolicy``
- ``MCPConnectionEvent``
- ``MCPConnectionState``
- ``MCPDisconnectReason``
- ``MCPError``

### Authorization and OAuth

- ``MCPAuthorization``
- ``MCPNoAuthorization``
- ``AuthRetryDecision``
- ``MCPAuthorizationRequest``
- ``MCPOAuthAuthorization``
- ``MCPOAuthTokenStore``
- ``MCPOAuthTokens``

### Tool policies and capabilities

- ``MCPApprovalPolicy``
- ``MCPCapabilities``

### Built-in Catalog

- ``MCPCatalog``
