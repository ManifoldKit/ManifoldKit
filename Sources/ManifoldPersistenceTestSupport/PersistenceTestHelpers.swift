import Foundation
import SwiftData
import ManifoldPersistenceSwiftData

/// Creates an in-memory `ModelContainer` suitable for unit and integration tests.
///
/// Delegates to ``ModelContainerFactory/makeInMemoryContainer()`` so the
/// container is configured with the current schema — the same setup used
/// in production. All SwiftData models (ChatMessage, ChatSession, SamplerPreset,
/// APIEndpoint, ModelBenchmarkCache) are registered. The container is ephemeral — nothing touches disk.
///
/// Split out of `ManifoldTestSupport/TestHelpers.swift` into
/// `ManifoldPersistenceTestSupport` (docs/plans/architecture-improvements-2026-07.md
/// item 4.4) — this is the one function in that file that actually needs the
/// SwiftData/ManifoldPersistenceSwiftData stack.
///
/// - Returns: A configured `ModelContainer` with in-memory storage.
/// - Throws: If `ModelContainer` initialisation fails (should not happen with
///   an in-memory configuration).
public func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainerFactory.makeInMemoryContainer()
}
