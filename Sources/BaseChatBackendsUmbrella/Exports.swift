// BaseChatBackends umbrella module.
//
// Initiative I7 split the original 11.7k-LOC `BaseChatBackends` target into
// five trait-gated family targets (`BaseChatCloudCore`, `BaseChatMLX`,
// `BaseChatLlama`, `BaseChatFoundation`, `BaseChatCloud`). This file is the
// thin re-export façade that keeps the existing `import BaseChatBackends`
// surface alive for downstream consumers (apps, the runtime UI module, the
// fuzz/server CLIs, and tests).
//
// Trait-gating rule (per CLAUDE.md): we gate the consumer→family edge in
// `Package.swift` (and the `@_exported import` here), not the
// family→library edge inside the family targets. Family targets always
// compile when their trait is on; the umbrella stays buildable in any
// trait combination.

@_exported import BaseChatInference
@_exported import BaseChatCloudCore

#if MLX
@_exported import BaseChatMLX
#endif

#if Llama
@_exported import BaseChatLlama
#endif

@_exported import BaseChatFoundation

#if CloudSaaS || Ollama
@_exported import BaseChatCloud
#endif
