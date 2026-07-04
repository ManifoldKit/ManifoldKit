import XCTest
import ManifoldInference
@testable import ManifoldTools

/// Verifies the shared `DecoyTools` pool's contract: fixed order (no RNG),
/// enough capacity for every consumer, unique names, and no collision with
/// the six reference tools — the properties the companion CLIs
/// (`manifold-tools-mlx` / `manifold-tools-llama`) depend on when they adopt
/// this pool in place of their own hand-maintained copies.
final class DecoyToolsTests: XCTestCase {

    /// The six built-in reference-tool names this pool must never collide
    /// with (see `ReferenceTools/*.swift`).
    private static let referenceToolNames: Set<String> = [
        "now", "calc", "read_file", "list_dir", "http_get_fixture", "sample_repo_search"
    ]

    func test_pool_hasAtLeast24Entries() {
        XCTAssertGreaterThanOrEqual(DecoyTools.maxCount, 24,
                                     "companions need headroom past --extra-tools 20")
    }

    func test_take_isDeterministicAcrossCalls() {
        let first = DecoyTools.take(10).map(\.name)
        let second = DecoyTools.take(10).map(\.name)
        XCTAssertEqual(first, second, "no RNG — take(_:) must return identical results every call")
    }

    func test_take_returnsFixedOrderPrefix() {
        let ten = DecoyTools.take(10).map(\.name)
        let twenty = DecoyTools.take(20).map(\.name)
        XCTAssertEqual(Array(twenty.prefix(10)), ten,
                       "take(20)'s first 10 must equal take(10) — growing N must not reorder")
    }

    func test_names_allUnique() {
        let names = DecoyTools.take(DecoyTools.maxCount).map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate decoy tool name in the pool")
    }

    func test_names_neverCollideWithReferenceTools() {
        let names = Set(DecoyTools.take(DecoyTools.maxCount).map(\.name))
        let collisions = names.intersection(Self.referenceToolNames)
        XCTAssertTrue(collisions.isEmpty, "decoy pool collides with reference tool(s): \(collisions)")
    }

    func test_take_zeroReturnsEmpty() {
        XCTAssertTrue(DecoyTools.take(0).isEmpty)
    }

    func test_take_negativeClampsToEmpty() {
        XCTAssertTrue(DecoyTools.take(-5).isEmpty)
    }

    func test_take_beyondMaxCountClampsToPoolSize() {
        let requested = DecoyTools.maxCount + 100
        XCTAssertEqual(DecoyTools.take(requested).count, DecoyTools.maxCount)
    }

    func test_names_matchesTakeNames() {
        let n = 5
        XCTAssertEqual(DecoyTools.names(n), DecoyTools.take(n).map(\.name))
    }

    func test_executors_countMatchesRequest() {
        let executors = DecoyTools.executors(6)
        XCTAssertEqual(executors.count, 6)
    }

    func test_executor_returnsInertMarkerAndNeverErrors() async throws {
        guard let executor = DecoyTools.executors(1).first else {
            return XCTFail("expected at least one decoy executor")
        }
        let result = try await executor.execute(arguments: .object([:]))
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains(executor.definition.name),
                      "decoy result should name itself so a wrong-tool call is traceable in the transcript")
    }

    func test_everyDefinition_hasNonEmptyDescriptionAndObjectSchema() {
        for definition in DecoyTools.take(DecoyTools.maxCount) {
            XCTAssertFalse(definition.description.isEmpty, "\(definition.name) has an empty description")
            guard case .object(let schema) = definition.parameters else {
                return XCTFail("\(definition.name) parameters is not a JSON object schema")
            }
            XCTAssertEqual(schema["type"], .string("object"))
        }
    }
}
