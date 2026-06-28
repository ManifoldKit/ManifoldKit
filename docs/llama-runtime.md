# ManifoldLlama — Runtime Behaviour (moved)

The `ManifoldLlama` backend moved to the
[`manifold-llama`](https://github.com/ManifoldKit/manifold-llama) companion
package in v0.48 (PR C2, #1749), and this runtime-behaviour document —
Metal offload policy, the `LLAMA_FORCE_CPU_ONLY=1` escape hatch, prompt-prefix
KV reuse semantics, the cancellation surface, and the memory-pressure
response — moved with it.

Consult it in that repository; it pairs with the llama.cpp C-API contract
document there.

For consumer-facing migration steps (installing the companion package and
registering `LlamaBackends`), see [MIGRATION-0.48.md](MIGRATION-0.48.md).
