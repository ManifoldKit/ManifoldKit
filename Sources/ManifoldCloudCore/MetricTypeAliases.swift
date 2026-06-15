// Source compatibility shim — InferenceMetric, InferenceMetricSink, and
// InMemoryMetricSink were relocated from ManifoldCloudCore to ManifoldInference
// in the observability train so that ManifoldFoundation (which depends on
// ManifoldInference but not ManifoldCloudCore) can reach them.
//
// @_exported re-surfaces the entire ManifoldInference surface through
// ManifoldCloudCore so all existing `import ManifoldCloudCore` consumers
// continue to resolve InferenceMetric / InferenceMetricSink / InMemoryMetricSink
// at the same import depth — no source changes required downstream.
//
// ManifoldCloudCore already takes a direct dependency on ManifoldInference in
// Package.swift, so this is a pure source-compat promotion, not a new dep.
@_exported import ManifoldInference
