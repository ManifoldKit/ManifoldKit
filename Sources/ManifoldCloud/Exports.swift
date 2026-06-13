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
// `import ManifoldCloud` keeps compiling via these re-exports; new code
// should import the specific module it needs. Since v0.48 PR A4
// (Ollama/CloudSaaS traits retired) both family re-exports are
// unconditional — the families always compile.
//
// DEPRECATION CLOCK (P7, target-architecture-migration.md): this shim is
// scheduled for removal. Swift cannot emit a deprecation warning on an
// `@_exported import` (the attribute applies to declarations, not modules),
// so the clock is tracked here + in the CHANGELOG/migration guide, not by
// the compiler. Window: ≥2 minors from v0.48 — earliest removal v0.50.0.
// Until then `import ManifoldCloud` stays source-compatible. Removal is part
// of the final P7 breaking release alongside the other re-export facades.
//
// `DefaultWebSearchRuntime` (WebSearch/) still lives here: it conforms to
// the `WebSearchRuntime` port from ManifoldRuntime, an edge neither
// provider target wants. Its final home is decided in the v0.48 train
// (PR A4/A5).

@_exported import ManifoldCloudCore

@_exported import ManifoldOllama

@_exported import ManifoldCloudSaaS
