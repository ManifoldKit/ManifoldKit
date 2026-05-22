# ManifoldKit Feature Matrix

Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.
Do not edit by hand — re-run the script.

| Trait | Description | Capabilities Unlocked |
|-------|-------------|-----------------------|
| `AnyLanguageModel` | Enable the AnyLanguageModel bridge backend target. | `localInference` |
| `AppIntents` | Enable the ManifoldAppIntents AppIntent ↔ ToolDefinition bridge. | `toolCalling` |
| `CloudSaaS` | Third-party SaaS providers (Claude, OpenAI). Off by default. | `cloudOpenAI`, `cloudClaude`, `toolCalling`, `visionInput` |
| `FoundationOnly` | App Store-lean: Apple Foundation Models only. Pass `traits: ["FoundationOnly"]` from the consumer manifest — overrides the MLX/Llama/HuggingFace default trait set. | `foundationBackend` |
| `Fuzz` | Enable real inference backends in fuzz-chat (Ollama, Llama, Foundation). Required by scripts/fuzz.sh; not needed for swift test or xcodebuild test. | _(none — harness/build lever)_ |
| `HuggingFace` | Enable HuggingFace Hub search, browse, and download | `modelDownload` |
| `Llama` | Enable the llama.cpp (GGUF) inference backend | `localInference`, `llamaBackend`, `embeddings` |
| `Macros` | Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph. | `toolCalling` |
| `MCP` | Enable the ManifoldMCP module and MCP client surface. | `mcpClient`, `mcpHost` |
| `MCPBuiltinCatalog` | Enable ManifoldMCP's built-in catalog descriptors. | `mcpClient` |
| `MLX` | Enable the MLX inference backend (requires Apple Silicon) | `localInference`, `mlxBackend`, `visionInput`, `imageGeneration` |
| `Ollama` | Self-hosted / private-datacenter HTTP inference. Moves out of defaults in next major. | `ollama`, `toolCalling`, `embeddings` |
| `Server` | Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency. | `embeddings` |
| `Tools` | Enable the ManifoldTools end-to-end tool-calling validation harness and its `manifold-tools` CLI. | `toolCalling` |
| `Voice` | Enable the ManifoldVoice speech I/O spike and voice composer UI. | `voiceIO` |
