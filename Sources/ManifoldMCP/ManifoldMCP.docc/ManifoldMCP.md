# ``ManifoldMCP``

Model Context Protocol (MCP) client primitives for ManifoldKit.

## Overview

`ManifoldMCP` provides the descriptor and client surface for attaching MCP servers to ``InferenceService`` tool execution. The module is intentionally split into:

- transport/auth/capability types (`MCPServerDescriptor`, `MCPTransportKind`, `MCPAuthorizationDescriptor`)
- connection + source lifecycle (`MCPClient`, `MCPToolSource`)
- catalog presets (`MCPCatalog`, gated by `MCPBuiltinCatalog`)

Use this module to model and audit tool boundaries before wiring concrete transport internals.

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
