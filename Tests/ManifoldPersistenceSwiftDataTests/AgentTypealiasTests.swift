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

    // The two tests below intentionally reference the deprecated `Agent`
    // alias — that is the behavior under test. Marking the test methods
    // themselves `@available(*, deprecated)` lets them use the alias without
    // emitting deprecation warnings (deprecated code may freely call
    // deprecated code); XCTest still discovers and runs them.

    @available(*, deprecated, message: "Intentionally exercises the deprecated Agent alias.")
    func test_agentDeprecatedAlias_stillResolvesForBackCompat() {
        // Host-app code using the old name must keep compiling (with a
        // migration warning pointing at `PersistedAgent`).
        // Sabotage: remove the `Agent` typealias and this test fails to compile.
        XCTAssertTrue(Agent.self == ManifoldSchemaV9.Agent.self)
    }

    @available(*, deprecated, message: "Intentionally exercises the deprecated Agent alias.")
    func test_persistedAgentAndDeprecatedAgent_areIdentical() {
        // Both aliases must point at the same class — diverging them
        // would silently fork the SwiftData identity model.
        XCTAssertTrue(PersistedAgent.self == Agent.self)
    }
}
