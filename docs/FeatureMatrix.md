# ManifoldKit Feature Matrix

Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.
Do not edit by hand — re-run the script.

| Trait | Description | Capabilities Unlocked |
|-------|-------------|-----------------------|
| `CoreAI` | Stub: Apple's CoreAI tensor runtime — confirmed a DEAD END for ManifoldKit. It consumes a proprietary .aimodel format (AIModel/InferenceFunction/NDArray) with no LanguageModel/ModelExecutor protocol and no GGUF/MLX path, so it is not a backend seam. Name is misleading; rename/retire in a later real-code PR. Pure no-op stub. | _(none — harness/build lever)_ |
| `Macros` | Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph. | `toolCalling` |
| `Server` | Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency. | `embeddings` |
| `SystemAIProviderExtension` | Stub: a third-party "system AI provider" backend slot — anticipated pre-WWDC but NOT found in the macOS 27 beta SDK (no SystemAIProvider symbol anywhere). The real third-party model seam is FoundationModels.LanguageModelExecutor (macOS 27/iOS 27). Pure no-op stub. | _(none — harness/build lever)_ |
