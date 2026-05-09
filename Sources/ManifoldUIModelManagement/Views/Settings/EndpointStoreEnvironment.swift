import SwiftUI
import ManifoldRuntime

/// Injection point for the ``EndpointStore`` consumed by
/// ``APIConfigurationView``, ``APIEndpointEditorView``, and
/// ``RemoteServerConfigSheet``.
///
/// Declared unconditionally (not behind the `Ollama` / `CloudSaaS` traits) so
/// host apps can wire `runtime.endpointStore` via `.environment(\.endpointStore, …)`
/// without per-trait `#if`s at the call site. The endpoint editor views
/// themselves remain trait-gated; they no-op (render `EmptyView`) when the
/// traits are off, regardless of whether a store is injected.
private struct EndpointStoreKey: EnvironmentKey {
    static let defaultValue: (any EndpointStore)? = nil
}

extension EnvironmentValues {
    public var endpointStore: (any EndpointStore)? {
        get { self[EndpointStoreKey.self] }
        set { self[EndpointStoreKey.self] = newValue }
    }
}
