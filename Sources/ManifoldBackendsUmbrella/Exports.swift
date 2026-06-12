// ManifoldBackends umbrella module.
//
// Since v0.48 (PR C2) this is the *loud-inside-silent* shim of the companion
// split (#1749): it re-exports only the families that remain in core —
// Foundation + Cloud. The MLX and llama.cpp families (and their
// `MLXBackends` / `LlamaBackends` registrars) live in the manifold-mlx /
// manifold-llama companion packages. Existing `import ManifoldBackends`
// consumers keep compiling against this shim, but local inference is GONE
// from core: add the companion package and pass its registrar to
// `ManifoldKit.quickStart(backends:)`. See docs/MIGRATION-0.48.md.

@_exported import ManifoldInference
@_exported import ManifoldCloudCore

@_exported import ManifoldFoundation

@_exported import ManifoldCloud
