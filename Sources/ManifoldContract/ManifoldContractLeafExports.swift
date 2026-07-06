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
//
// Why the tool-calling vocabulary and BackendCapabilities stay down in
// ManifoldHardware instead of physically relocating to ManifoldContract
// (considered and ruled out during the pre-1.0 API review, 2026-07):
// ManifoldHardware's own sources already consume them load-bearingly —
// `StructuredOutputStrategy` takes `JSONSchemaValue` and `BackendCapabilities`
// parameters, `PromptTemplate` serialises `ToolDefinition` into dialect
// prompts, and `GenerationCapabilityRequirement.satisfies(_:)` extends
// `BackendCapabilities` directly. Moving the types up to ManifoldContract
// would make ManifoldHardware depend on a module that depends on
// ManifoldHardware — a cycle. Per the API-review posture, this is fine: the
// SwiftPM *products* are the API contract consumers build against, not
// per-file module placement, and this re-export is exactly what keeps the
// two aligned.
@_exported import ManifoldHardware
@_exported import ManifoldModelCatalog
