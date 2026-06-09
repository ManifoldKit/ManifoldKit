// ManifoldContract sits one layer above the P1 leaf modules
// (ManifoldHardware, ManifoldModelCatalog) extracted in #1608–#1611. The
// Contract surface (InferenceBackend, GenerationConfig, GenerationEvent,
// Message, …) is expressed in terms of those leaf value types —
// `ToolDefinition`/`JSONSchemaValue`/`ToolChoice`/`BackendCapabilities`/
// `ModelLoadPlan`/`InferenceError` from ManifoldHardware and
// `ModelManifest`/`CloudBackendError`/`ImageGenerationConfig`/… from
// ManifoldModelCatalog.
//
// Re-exporting them here serves two purposes:
//  1. ManifoldContract's own sources see the leaf symbols module-wide
//     without a per-file `import` (these files were sibling-visible inside
//     ManifoldInference before the downward extraction in #1719).
//  2. Consumers that `import ManifoldContract` (the family backends) keep
//     resolving the leaf types they already used through ManifoldInference's
//     `@_exported import` chain — preserving source compatibility.
@_exported import ManifoldHardware
@_exported import ManifoldModelCatalog
