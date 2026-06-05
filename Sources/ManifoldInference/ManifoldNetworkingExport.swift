// Back-compat re-export shim for P1a of the target-architecture migration
// (#1608). `NetworkActivityCenter`, `NetworkActivityTrackingDelegate`, and
// `PrivateIPClassifier` were evicted from the kernel into the leaf module
// `ManifoldNetworking`. Re-exporting it here keeps every existing
// `import ManifoldInference` call site resolving those symbols unchanged, so
// the move is source-compatible for downstream consumers.
@_exported import ManifoldNetworking
