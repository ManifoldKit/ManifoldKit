# LlamaSwift xcframework — llama.cpp C API Contract (moved)

The `ManifoldLlama` backend — and with it the full llama.cpp C-API contract
this document used to describe (per-symbol threading constraints, ordering
invariants, capacity limits, ownership semantics, sampling-chain coverage,
and the xcframework-pin upgrade workflow) — moved to the
[`manifold-llama`](https://github.com/ManifoldKit/manifold-llama) companion
package in v0.48 (PR C2, #1749).

The contract document now lives in that repository alongside the sources it
audits. Consult it there when upgrading the `mattt/llama.swift` pin.

For consumer-facing migration steps (installing the companion package and
registering `LlamaBackends`), see [MIGRATION-0.48.md](MIGRATION-0.48.md).
