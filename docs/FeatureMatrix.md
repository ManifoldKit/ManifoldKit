# ManifoldKit Feature Matrix

**Audience:** consumer
**Status:** living

Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.
Do not edit by hand — re-run the script.

> **Remaining SwiftPM traits only.** This table lists the opt-in traits still
> declared in `Package.swift` (`Macros` and `Server`) — it is
> **not** a full product or backend capability map. Most capabilities compile
> unconditionally in core, or ship in the `manifold-mlx` / `manifold-llama`
> companion packages. For the real surface see [AGENTS.md](../AGENTS.md)
> (products) and [COMPANION-BACKENDS.md](COMPANION-BACKENDS.md).

| Trait | Description | Capabilities Unlocked |
|-------|-------------|-----------------------|
| `Macros` | Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph. | `toolCalling` |
| `Server` | Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency. | `embeddings` |
