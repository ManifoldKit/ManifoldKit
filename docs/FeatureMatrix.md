# ManifoldKit Feature Matrix

Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.
Do not edit by hand — re-run the script.

| Trait | Description | Capabilities Unlocked |
|-------|-------------|-----------------------|
| `CoreAI` | Placeholder for Apple's rumoured Core AI framework (Core ML successor). No-op until WWDC 2026 confirms the surface. | _(none — harness/build lever)_ |
| `Macros` | Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph. | `toolCalling` |
| `Server` | Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency. | `embeddings` |
| `SystemAIProviderExtension` | Stubs for the iOS 27 system AI provider extension surface (Siri/Writing Tools backend slot). No-op until WWDC 2026 ships the API. | _(none — harness/build lever)_ |
