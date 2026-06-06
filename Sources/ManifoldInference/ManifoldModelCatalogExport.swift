// Back-compat re-export shim for P1d of the target-architecture migration
// (#1611). Model discovery/catalog/benchmark types and image/video-gen records
// were evicted from the kernel into the leaf module `ManifoldModelCatalog`.
// Re-exporting it here keeps every existing `import ManifoldInference` call
// site resolving those symbols unchanged, so the move is source-compatible.
@_exported import ManifoldModelCatalog
