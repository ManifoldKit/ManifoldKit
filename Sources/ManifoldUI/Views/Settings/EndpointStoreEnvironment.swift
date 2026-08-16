import SwiftUI
import ManifoldRuntime

/// Injection point for the ``EndpointStore`` consumed by host-supplied API
/// configuration views.
///
/// ``ChatView`` re-injects this value into its API-configuration presentations,
/// because SwiftUI does not reliably carry custom ``EnvironmentValues`` keys
/// from a host ancestor into sheet or popover content. Declare the key in
/// `ManifoldUI`, which owns that presentation boundary, while concrete editor
/// views continue to live in `ManifoldUIModelManagement`.
private struct EndpointStoreKey: EnvironmentKey {
    static let defaultValue: (any EndpointStore)? = nil
}

extension EnvironmentValues {
    public var endpointStore: (any EndpointStore)? {
        get { self[EndpointStoreKey.self] }
        set { self[EndpointStoreKey.self] = newValue }
    }
}
