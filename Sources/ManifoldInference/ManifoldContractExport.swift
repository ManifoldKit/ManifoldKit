// Back-compat re-export shim for P2a of the target-architecture migration
// (#1719). The Contract surface that family backends compile against — the
// backend protocols (`InferenceBackend`, `EmbeddingBackend`,
// `ImageGenerationBackend`, `Reranker`, `TokenizerProvider`,
// `LocalInferenceAdapter`, `ToolExecutor`, the `BackendOptInProtocols`
// family), the value/stream types (`GenerationConfig`, `GenerationEvent`,
// `GenerationStream`, `Message`, `MessagePart`, `ChatError`, `BackendName`,
// `BackendVisionCapability`, `VectorSearchHit`, `AgentDefinition`/`AgentHandoff`), and
// the backend-facing streaming utilities (`StreamTransform`,
// `ToolCallTransform`, `ThinkingTransform`, `OutputParserSession`,
// `GrammarPhaseGate`, `SSEStreamParser`, `StreamingArgumentAccumulator`,
// `HeuristicTokenizer`) — was extracted *downward* into the zero-engine-
// dependency leaf module `ManifoldContract`. `ManifoldInference` keeps its
// name and remains the engine (InferenceService, GenerationQueue,
// ToolRegistry, BackendRegistrar, …).
//
// Re-exporting Contract here keeps every existing `import ManifoldInference`
// call site resolving those symbols unchanged, so the move is source-
// compatible for all downstream consumers (zero import edits). Mirrors the
// P1 leaf shims (ManifoldHardwareExport / ManifoldModelCatalogExport /
// ManifoldNetworkingExport / ManifoldSecretsExport).
@_exported import ManifoldContract
