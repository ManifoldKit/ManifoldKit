import Foundation
import Observation

/// A main-actor observable store for non-fatal operational warnings.
///
/// Background tasks (benchmark caching, file cleanup, auto-rename) call
/// `record(_:)` when they hit a recoverable failure. The UI observes
/// `warnings` to surface a disclosure under settings or a badge in the
/// chrome. Warnings are append-only with a fixed-size ring so a runaway
/// producer can't exhaust memory.
///
/// Placed in `ManifoldCore` so both the UI layer and view models can
/// share the same instance without a back-dependency on `ManifoldUI`.
@Observable
@MainActor
public final class DiagnosticsService {

    /// Maximum number of warnings retained. Oldest entries are evicted
    /// when this cap is exceeded. 50 is large enough to capture a
    /// clustered outage but small enough to be bounded in memory.
    public static let defaultCapacity = 50

    /// All currently retained warnings, newest first.
    public private(set) var warnings: [OperationalWarning] = []

    private let capacity: Int

    public init(capacity: Int = DiagnosticsService.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Appends a new warning for the given error. Oldest entries are
    /// evicted once the store exceeds `capacity`.
    public func record(_ error: OperationalError) {
        let warning = OperationalWarning(error: error)
        warnings.insert(warning, at: 0)
        if warnings.count > capacity {
            warnings.removeLast(warnings.count - capacity)
        }
    }

    /// Removes the warning with the given identifier, if it exists.
    public func dismiss(_ id: UUID) {
        warnings.removeAll { $0.id == id }
    }

    /// Removes every retained warning.
    public func dismissAll() {
        warnings.removeAll()
    }

    /// `true` when no warnings are currently retained.
    public var isEmpty: Bool { warnings.isEmpty }

    /// Number of warnings currently retained.
    public var count: Int { warnings.count }
}
