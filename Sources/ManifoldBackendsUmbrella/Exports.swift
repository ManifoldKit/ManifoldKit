// ManifoldBackends umbrella module.
//
// Initiative I7 split the original 11.7k-LOC `ManifoldBackends` target into
// five trait-gated family targets (`ManifoldCloudCore`, `ManifoldMLX`,
// `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`). This file is the
// thin re-export façade that keeps the existing `import ManifoldBackends`
// surface alive for downstream consumers (apps, the runtime UI module, the
// fuzz/server CLIs, and tests).
//
// Trait-gating rule (per CLAUDE.md): we gate the consumer→family edge in
// `Package.swift` (and the `@_exported import` here), not the
// family→library edge inside the family targets. Only the MLX / Llama
// edges remain trait-gated; the cloud edges are unconditional since the
// Ollama / CloudSaaS traits retired in v0.48 (PR A4). The umbrella stays
// buildable in any trait combination.

@_exported import ManifoldInference
@_exported import ManifoldCloudCore

#if MLX
@_exported import ManifoldMLX
#endif

#if Llama
@_exported import ManifoldLlama
#endif

@_exported import ManifoldFoundation

@_exported import ManifoldCloud
