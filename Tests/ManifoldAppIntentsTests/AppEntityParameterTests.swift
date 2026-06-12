import XCTest
import ManifoldInference
@testable import ManifoldAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - AppEntity fixtures

/// Minimal in-memory `AppEntity` used to exercise the schema-builder + executor
/// resolver path. The query is backed by a static store so the test resolver
/// behavior is deterministic without touching the system AppIntents framework.
@available(iOS 26, macOS 26, *)
struct Book: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static let defaultQuery = BookQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(stringLiteral: title)
    }
}

@available(iOS 26, macOS 26, *)
struct BookQuery: EntityQuery {
    static let store: [String: Book] = [
        "b1": Book(id: "b1", title: "Dune"),
        "b2": Book(id: "b2", title: "Foundation"),
    ]
    func entities(for ids: [Book.ID]) async throws -> [Book] {
        ids.compactMap { Self.store[$0] }
    }
}

/// Intent that takes a single `Book` parameter. `init(from:)` reads the
/// resolved entity out of the decoder's `userInfo`; the model never sends the
/// full entity, only `{ "id": "..." }`.
@available(iOS 26, macOS 26, *)
struct DescribeBookIntent: AppIntent, Decodable {
    static let title: LocalizedStringResource = "Describe Book"

    @Parameter(title: "Book")
    var book: Book

    init() { self.book = Book(id: "", title: "") }

    init(from decoder: Decoder) throws {
        self.init()
        // Resolved entity arrives via userInfo — see
        // `AppIntentToolExecutor.resolveEntityArguments`.
        if let resolved: Book = decoder.resolvedAppEntity("book") {
            self.book = resolved
        } else {
            throw DecodingError.valueNotFound(
                Book.self,
                .init(codingPath: [], debugDescription: "missing resolved book")
            )
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "Book: \(book.title)")
    }
}

/// Resolver that always throws — used to verify error classification.
@available(iOS 26, macOS 26, *)
struct ThrowingResolver: AppEntityResolver {
    struct Boom: LocalizedError {
        var errorDescription: String? { "resolver exploded" }
    }
    func resolve<E: AppEntity>(_ entityType: E.Type, id: E.ID) async throws -> E? {
        throw Boom()
    }
}

/// Resolver used in the happy path that defers to `Book.defaultQuery` so the
/// executor's `DefaultAppEntityResolver` path is also exercised implicitly.
@available(iOS 26, macOS 26, *)
struct InMemoryBookResolver: AppEntityResolver {
    func resolve<E: AppEntity>(_ entityType: E.Type, id: E.ID) async throws -> E? {
        guard entityType == Book.self, let stringID = id as? String else { return nil }
        return BookQuery.store[stringID] as? E
    }
}

// MARK: - Cross-module enum fixture (PR #1381 gap coverage)

/// Top-level enum so `_typeByName` has a fully-qualified name to resolve. The
/// schema builder lives in `ManifoldAppIntents`; this type lives in the test
/// module — a different module — proving the runtime lookup crosses boundaries.
@available(iOS 26, macOS 26, *)
enum CrossModulePriority: String, AppEnum, IntentEnumParameter {
    case low, medium, high

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Priority")
    static let caseDisplayRepresentations: [CrossModulePriority: DisplayRepresentation] = [
        .low: "Low",
        .medium: "Medium",
        .high: "High",
    ]
}

@available(iOS 26, macOS 26, *)
struct PrioritizedIntent: AppIntent, Decodable {
    static let title: LocalizedStringResource = "Prioritized"

    @Parameter(title: "Priority")
    var priority: CrossModulePriority

    init() { self.priority = .low }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let raw = try c.decode(String.self, forKey: .priority)
        self.priority = CrossModulePriority(rawValue: raw) ?? .low
    }

    private enum CodingKeys: String, CodingKey { case priority }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: priority.rawValue)
    }
}

// MARK: - Non-Encodable result fixture (PR #1381 gap coverage)

/// `IntentResult` whose payload is `String(describing:)`-only. `.result()`
/// returns a private framework type that is not generically `Encodable`, so the
/// serialiser must fall back to `String(describing:)` — this fixture exercises
/// that fallback path without contriving a custom result wrapper.
@available(iOS 26, macOS 26, *)
struct VoidResultIntent: AppIntent, Decodable {
    static let title: LocalizedStringResource = "Void"

    @Parameter(title: "Tag")
    var tag: String

    init() { self.tag = "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.tag = try c.decode(String.self, forKey: .tag)
    }

    private enum CodingKeys: String, CodingKey { case tag }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - Tests

@available(iOS 26, macOS 26, *)
final class AppEntityParameterTests: XCTestCase {

    // MARK: schema synthesis

    func testSchemaEmitsIdOnlyObjectForAppEntityParameter() throws {
        try skipUnlessAppIntents26Runtime()
        let executor = AppIntentToolExecutor(
            DescribeBookIntent.self,
            approvalPolicy: .readOnlyAutoApprove,
            entityResolver: InMemoryBookResolver()
        )
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        guard case .object(let bookSchema) = properties["book"] else {
            return XCTFail("`book` schema must be an object; got \(String(describing: properties["book"]))")
        }
        XCTAssertEqual(bookSchema["type"], .string("object"))

        guard case .object(let bookProperties) = bookSchema["properties"] else {
            return XCTFail("`book` schema must declare nested properties")
        }
        guard case .object(let idSchema) = bookProperties["id"] else {
            return XCTFail("`book.id` schema must be an object")
        }
        XCTAssertEqual(idSchema["type"], .string("string"), "Book.ID is String → id schema must be `string`")

        guard case .array(let required) = bookSchema["required"] else {
            return XCTFail("`book` schema must declare required = [id]")
        }
        XCTAssertEqual(required, [.string("id")])
    }

    // MARK: happy path

    func testExecuteResolvesEntityByIdAndRunsPerform() async throws {
        try skipUnlessAppIntents26Runtime()
        let executor = AppIntentToolExecutor(
            DescribeBookIntent.self,
            approvalPolicy: .readOnlyAutoApprove,
            entityResolver: InMemoryBookResolver()
        )
        let args = JSONSchemaValue.object([
            "book": .object(["id": .string("b1")]),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(
            result.errorKind,
            "happy path must not produce an error kind; got \(String(describing: result.errorKind)): \(result.content)"
        )
        XCTAssertTrue(
            result.content.contains("Dune"),
            "result body must include the resolved title; got \(result.content)"
        )
    }

    // MARK: unknown id

    func testExecuteWithUnknownEntityIdReturnsInvalidArguments() async throws {
        try skipUnlessAppIntents26Runtime()
        let executor = AppIntentToolExecutor(
            DescribeBookIntent.self,
            approvalPolicy: .readOnlyAutoApprove,
            entityResolver: InMemoryBookResolver()
        )
        let args = JSONSchemaValue.object([
            "book": .object(["id": .string("missing")]),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(
            result.errorKind,
            .invalidArguments,
            "unresolved entity id must surface as .invalidArguments"
        )
        XCTAssertTrue(
            result.content.contains("Book"),
            "error message should name the entity type; got: \(result.content)"
        )
        XCTAssertTrue(
            result.content.contains("missing"),
            "error message should name the unresolved id; got: \(result.content)"
        )
    }

    // MARK: resolver throws

    func testExecuteWithThrowingResolverSurfacesPermanent() async throws {
        try skipUnlessAppIntents26Runtime()
        let executor = AppIntentToolExecutor(
            DescribeBookIntent.self,
            approvalPolicy: .readOnlyAutoApprove,
            entityResolver: ThrowingResolver()
        )
        let args = JSONSchemaValue.object([
            "book": .object(["id": .string("b1")]),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(
            result.errorKind,
            .permanent,
            "resolver-thrown errors must classify as .permanent (no auth heuristic match)"
        )
        XCTAssertTrue(
            result.content.contains("resolver exploded"),
            "underlying error description must surface; got: \(result.content)"
        )
    }

    // MARK: cross-module enum lookup (PR #1381 gap)

    func testSchemaResolvesEnumDefinedInTestModule() {
        let executor = AppIntentToolExecutor(PrioritizedIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"],
              case .object(let prioritySchema) = properties["priority"]
        else {
            return XCTFail("schema must contain `priority` as an object")
        }
        XCTAssertEqual(prioritySchema["type"], .string("string"))
        guard case .array(let cases) = prioritySchema["enum"] else {
            return XCTFail("priority schema must publish `enum: [...]`; got \(prioritySchema)")
        }
        // Order is declaration order; this proves _typeByName resolved the
        // type AND the builder enumerated all cases.
        XCTAssertEqual(cases, [.string("low"), .string("medium"), .string("high")])
    }

    // MARK: non-Encodable result fallback (PR #1381 gap)

    func testNonEncodableIntentResultFallsBackToStringDescription() async throws {
        let executor = AppIntentToolExecutor(
            VoidResultIntent.self,
            approvalPolicy: .readOnlyAutoApprove
        )
        let args = JSONSchemaValue.object([
            "tag": .string("hello"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind, "void-result intent must execute without error")
        // Without contriving an Encodable conformance, `.result()` produces a
        // framework type whose body falls through to `String(describing:)`.
        // We can't assert the exact string (it's a private framework type),
        // but it must be non-empty — the fallback engaged.
        XCTAssertFalse(
            result.content.isEmpty,
            "fallback content must be non-empty even when the result isn't Encodable"
        )
    }
}

#endif // canImport(AppIntents)
