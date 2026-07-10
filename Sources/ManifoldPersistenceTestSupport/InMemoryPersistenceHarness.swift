import Foundation
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference

/// Builds a fresh in-memory SwiftData stack wrapped in the production
/// ``SwiftDataPersistenceProvider``.
///
/// Tests that exercise persistence behaviour should use this harness rather
/// than a hand-rolled mock — it catches schema mismatches, predicate bugs,
/// and ordering regressions that in-memory arrays silently accept. The
/// container is ephemeral and must not be reused across tests; call
/// ``make()`` from every `setUp`.
///
/// ```swift
/// override func setUp() async throws {
///     stack = try InMemoryPersistenceHarness.make()
/// }
/// ```
///
/// > Important: Hold onto the returned ``Stack`` (store it on the test case
/// > for the duration of the test). If the stack is only captured inside a
/// > helper function and that function returns, the `ModelContainer` is
/// > deallocated, the underlying `ModelContext` becomes invalid, and
/// > SwiftData will trap on the next fetch/save with `SIGTRAP`.
@MainActor
public enum InMemoryPersistenceHarness {

    /// Bundles the SwiftData stack so callers can both drive the public
    /// provider and poke at the raw `ModelContext` for ad-hoc assertions.
    public struct Stack {
        public let container: ModelContainer
        public let context: ModelContext
        public let provider: SwiftDataPersistenceProvider
    }

    /// Creates a fresh in-memory stack. Safe to call from `setUp`.
    ///
    /// The caller can verify the store is in-memory by asserting on
    /// ``isInMemoryStore(_:)`` — kept as an explicit check rather than a
    /// `precondition` so a misconfiguration surfaces as a test failure
    /// instead of crashing every suite that shares the harness.
    public static func make() throws -> Stack {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let provider = SwiftDataPersistenceProvider(modelContext: context)
        return Stack(container: container, context: context, provider: provider)
    }

    /// Returns `true` when the container is backed by an in-memory store.
    /// SwiftData resolves in-memory configurations to a `/dev/null` URL.
    public static func isInMemoryStore(_ container: ModelContainer) -> Bool {
        container.configurations.first?.url.path == "/dev/null"
    }
}
