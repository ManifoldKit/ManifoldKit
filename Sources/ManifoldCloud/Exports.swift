// ManifoldCloud is a deprecated re-export shim as of v0.48.
//
// The cloud backend sources moved into two real targets so each family can
// ship as its own library product:
//   - `ManifoldOllama`    — Ollama (self-hosted / LAN) backend
//   - `ManifoldCloudSaaS` — Claude, OpenAI Chat Completions, OpenAI
//                           Responses, LM Studio / custom endpoints
// Shared infrastructure (`CloudMessageEncoder`, `CloudPayloadHandler`,
// `CloudHTTPProviderAdapter`, the OpenAI-compatible parsing) sank into
// `ManifoldCloudCore`.
//
// `import ManifoldCloud` keeps compiling for one release via these
// re-exports; new code should import the specific module it needs. The
// `#if` gates mirror the trait-gated consumer→product edges in
// Package.swift (this shim is the one place a per-trait `@_exported
// import` still needs a compilation condition).
//
// `DefaultWebSearchRuntime` (WebSearch/) still lives here: it conforms to
// the `WebSearchRuntime` port from ManifoldRuntime, an edge neither
// provider target wants. Its final home is decided in the v0.48 train
// (PR A4/A5).

@_exported import ManifoldCloudCore

#if Ollama
@_exported import ManifoldOllama
#endif

#if CloudSaaS
@_exported import ManifoldCloudSaaS
#endif
