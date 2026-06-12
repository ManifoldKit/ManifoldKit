// Re-export of ManifoldSkills via the umbrella `ManifoldKit` module.
// Unconditional since v0.48 (the `Skills` trait was retired in PR A3) —
// the module body is platform-gated with `#if os(macOS)` and compiles to a
// no-op registry elsewhere, so the link cost is negligible.
@_exported import ManifoldSkills
