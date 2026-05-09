# MCP app privacy checklist

Use this checklist before shipping MCP-backed tools in your app.

## Descriptor and consent

- [ ] Set a user-readable ``MCPServerDescriptor.dataDisclosure`` for each server.
- [ ] Prefer explicit `toolNamespace` values so users can identify source systems.
- [ ] Restrict scope with ``MCPToolFilter`` (allow list first, avoid `allowAll` unless necessary).
- [ ] Set an ``MCPApprovalPolicy`` that matches your trust model.

## OAuth and tokens

- [ ] Use OAuth descriptors with least-privilege scopes.
- [ ] Keep `redirectURI` app-specific and controlled by your app.
- [ ] Provide a secure ``MCPOAuthRedirectListener`` implementation.
- [ ] Use a persistent token store appropriate for your platform (default `.keychain`).
- [ ] Handle `authorizationRequired` and scope downgrade events in your UX.

## Runtime handling

- [ ] Register/unregister `MCPToolSource` explicitly with view/session lifecycle.
- [ ] Show server identity (`displayName`) and requested capabilities before enabling.
- [ ] Log tool calls at a policy level (what was invoked, by which server), without storing sensitive payloads unless required.
- [ ] On disconnect/sign-out, revoke or delete stored tokens where applicable.

## Current module scope

`ManifoldMCP` currently focuses on MCP tool execution. If your app exposes resources/prompts/logging UX, build additional consent and redaction policy around those surfaces.
