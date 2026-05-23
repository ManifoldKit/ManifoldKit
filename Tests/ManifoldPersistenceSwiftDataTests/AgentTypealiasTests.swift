import XCTest
@testable import ManifoldPersistenceSwiftData

/// Verifies the F3 typealias disambiguation:
///
/// - ``PersistedAgent`` is the preferred public name for the SwiftData
///   `@Model` agent row.
/// - ``Agent`` is preserved as a back-compat alias so existing code keeps
///   compiling.
///
/// Both names must resolve to the same underlying `@Model` class
/// (`ManifoldSchemaV9.Agent`) — diverging them would silently break
/// SwiftData identity tracking and require a schema migration.
final class AgentTypealiasTests: XCTestCase {

    func test_persistedAgentTypealias_equalsSchemaV9Agent() {
        // Preferred name in new code. Sabotage: point PersistedAgent at any
        // other type (e.g. ChatSession) and this assertion fails.
        XCTAssertTrue(PersistedAgent.self == ManifoldSchemaV9.Agent.self)
    }

    func test_agentTypealias_stillResolvesForBackCompat() {
        // Back-compat alias kept so pre-F3 host apps keep compiling.
        // Sabotage: remove the `Agent` typealias and this test fails to
        // compile.
        XCTAssertTrue(Agent.self == ManifoldSchemaV9.Agent.self)
    }

    func test_persistedAgentAndAgent_areIdentical() {
        // Both aliases must point at the same class — diverging them
        // would silently fork the SwiftData identity model.
        XCTAssertTrue(PersistedAgent.self == Agent.self)
    }
}
