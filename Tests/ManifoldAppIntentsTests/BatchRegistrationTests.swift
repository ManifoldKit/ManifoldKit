import XCTest
import ManifoldInference
@testable import ManifoldAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Fixtures

/// Simple intent that adopts DiscoverableAppIntent — the primary marker path.
@available(iOS 26, macOS 26, *)
struct FooIntent: DiscoverableAppIntent {
    static let title: LocalizedStringResource = "Foo"

    @Parameter(title: "Value")
    var value: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.value = try c.decode(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "foo:\(value)")
    }
}

/// Second intent that does NOT adopt DiscoverableAppIntent — used to exercise
/// the `(AppIntent & Decodable).Type` heterogeneous overload.
@available(iOS 26, macOS 26, *)
struct BarIntent: AppIntent, Decodable {
    static let title: LocalizedStringResource = "Bar"

    @Parameter(title: "Count")
    var count: Int

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.count = try c.decode(Int.self, forKey: .count)
    }

    private enum CodingKeys: String, CodingKey { case count }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: count * 2)
    }
}

/// Third intent that adopts DiscoverableAppIntent for batch-of-three tests.
@available(iOS 26, macOS 26, *)
struct BazIntent: DiscoverableAppIntent {
    static let title: LocalizedStringResource = "Baz"

    @Parameter(title: "Flag")
    var flag: Bool

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.flag = try c.decode(Bool.self, forKey: .flag)
    }

    private enum CodingKeys: String, CodingKey { case flag }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: !flag)
    }
}

// MARK: - Tests

@available(iOS 26, macOS 26, *)
final class BatchRegistrationTests: XCTestCase {

    // MARK: - DiscoverableAppIntent conformance

    /// Any DiscoverableAppIntent metatype must be assignable to both
    /// `any AppIntent.Type` and `any Decodable.Type`, confirming the protocol
    /// refines both bases at the type level.
    func testDiscoverableAppIntentConformsToAppIntentAndDecodable() {
        let intentType: any DiscoverableAppIntent.Type = FooIntent.self
        let asAppIntent: any AppIntent.Type = intentType
        let asDecodable: any Decodable.Type = intentType
        // Accessing the metatypes is the conformance proof; equality assertions
        // prevent the compiler from eliminating the casts as dead code.
        XCTAssertTrue(asAppIntent == FooIntent.self)
        XCTAssertTrue(asDecodable == FooIntent.self)
    }

    // MARK: - registerAppIntents (DiscoverableAppIntent overload)

    /// Registering two DiscoverableAppIntent types must create one named
    /// executor per type, each with a correctly snake-cased name.
    @MainActor
    func testRegisterDiscoverableIntentsCreatesOneExecutorPerType() {
        let registry = ToolRegistry()
        registry.registerAppIntents([FooIntent.self, BazIntent.self])

        XCTAssertTrue(
            registry.contains(name: "foo_intent"),
            "foo_intent must be registered after batch call"
        )
        XCTAssertTrue(
            registry.contains(name: "baz_intent"),
            "baz_intent must be registered after batch call"
        )

        // Sabotage: remove BazIntent.self from the array above → baz_intent absent,
        // XCTAssertTrue on baz_intent fails.
    }

    /// Each executor must carry the name derived from its own type, not a shared
    /// name from the last (or first) element in the array.
    @MainActor
    func testEachBatchedExecutorCarriesItsOwnName() {
        let registry = ToolRegistry()
        registry.registerAppIntents([FooIntent.self, BazIntent.self])

        let fooExec = registry.executor(for: "foo_intent")
        let bazExec = registry.executor(for: "baz_intent")

        XCTAssertEqual(
            fooExec?.definition.name, "foo_intent",
            "executor for FooIntent must carry the correct snake-cased name"
        )
        XCTAssertEqual(
            bazExec?.definition.name, "baz_intent",
            "executor for BazIntent must carry the correct snake-cased name"
        )
    }

    // MARK: - registerAppIntents (heterogeneous (AppIntent & Decodable).Type overload)

    /// The `(AppIntent & Decodable).Type` overload must register all types in the
    /// array, including both DiscoverableAppIntent and plain conformances.
    @MainActor
    func testRegisterHeterogeneousTypesArray() {
        let registry = ToolRegistry()
        let types: [any (AppIntent & Decodable).Type] = [FooIntent.self, BarIntent.self]
        registry.registerAppIntents(types)

        XCTAssertTrue(registry.contains(name: "foo_intent"), "foo_intent must be registered")
        XCTAssertTrue(registry.contains(name: "bar_intent"), "bar_intent must be registered")
    }

    // MARK: - End-to-end dispatch

    /// Dispatching through ToolRegistry must reach the correct batch-registered
    /// intent and return the expected result from its `perform()`.
    @MainActor
    func testBatchRegisteredFooIntentDispatchesCorrectly() async {
        let registry = ToolRegistry()
        registry.registerAppIntents(
            [FooIntent.self, BazIntent.self],
            approvalPolicy: .readOnlyAutoApprove
        )

        let nonce = "§BATCH§\(UUID().uuidString.prefix(8))"
        let call = ToolCall(
            id: "foo-1",
            toolName: "foo_intent",
            arguments: "{\"value\": \"\(nonce)\"}"
        )

        let result = await registry.dispatch(call)

        XCTAssertNil(
            result.errorKind,
            "batch-registered intent must dispatch without error; got \(String(describing: result.errorKind)): \(result.content)"
        )
        // FooIntent prepends "foo:" to the value; the nonce must survive the
        // perform → serialise round-trip.
        XCTAssertTrue(
            result.content.contains(nonce),
            "result must echo the nonce; got \(result.content)"
        )

        // Sabotage check (manual): assert result.content.contains("WRONG") fails.
    }

    @MainActor
    func testBatchRegisteredBarIntentDispatchesViaHeterogeneousOverload() async {
        let registry = ToolRegistry()
        let types: [any (AppIntent & Decodable).Type] = [FooIntent.self, BarIntent.self]
        registry.registerAppIntents(types, approvalPolicy: .readOnlyAutoApprove)

        let call = ToolCall(
            id: "bar-1",
            toolName: "bar_intent",
            arguments: "{\"count\": 6}"
        )

        let result = await registry.dispatch(call)

        XCTAssertNil(
            result.errorKind,
            "bar_intent dispatch must not error; got \(String(describing: result.errorKind)): \(result.content)"
        )
        // BarIntent returns count * 2 = 12.
        XCTAssertTrue(
            result.content.contains("12"),
            "result must contain the doubled count (6*2=12); got \(result.content)"
        )
    }

    // MARK: - approvalPolicy propagation

    /// The uniform approvalPolicy must be applied to every executor in the
    /// batch — not only the first or last.
    @MainActor
    func testReadOnlyAutoApprovePropagatesAcrossAllBatchedExecutors() {
        let registry = ToolRegistry()
        registry.registerAppIntents(
            [FooIntent.self, BazIntent.self],
            approvalPolicy: .readOnlyAutoApprove
        )

        let fooRequires = registry.executor(for: "foo_intent")?.requiresApproval
        let bazRequires = registry.executor(for: "baz_intent")?.requiresApproval

        XCTAssertEqual(fooRequires, false, "foo_intent should not require approval (readOnly)")
        XCTAssertEqual(bazRequires, false, "baz_intent should not require approval (readOnly)")

        // Sabotage: change .readOnlyAutoApprove to .requiresUserApproval above
        // → both assertions flip to unexpected true.
    }

    @MainActor
    func testRequiresUserApprovalIsDefaultForBatchRegistration() {
        let registry = ToolRegistry()
        registry.registerAppIntents([FooIntent.self])

        let requires = registry.executor(for: "foo_intent")?.requiresApproval
        XCTAssertEqual(requires, true, "batch-registered intents default to requiresUserApproval")
    }

    // MARK: - Empty array is a no-op

    @MainActor
    func testRegisterEmptyDiscoverableArrayIsNoOp() {
        let registry = ToolRegistry()
        registry.registerAppIntents([] as [any DiscoverableAppIntent.Type])
        XCTAssertTrue(registry.definitions.isEmpty, "empty DiscoverableAppIntent array must produce no executors")
    }

    @MainActor
    func testRegisterEmptyHeterogeneousArrayIsNoOp() {
        let registry = ToolRegistry()
        registry.registerAppIntents([] as [any (AppIntent & Decodable).Type])
        XCTAssertTrue(registry.definitions.isEmpty, "empty heterogeneous array must produce no executors")
    }

    // MARK: - AppIntentApprovalPolicy top-level accessibility

    /// AppIntentApprovalPolicy must be addressable at the top level — no
    /// generic argument required — because batch-registration call sites don't
    /// have a concrete Intent type to hang the nested type off.
    func testApprovalPolicyIsAccessibleWithoutGenericArgument() {
        let require: AppIntentApprovalPolicy = .requiresUserApproval
        let readOnly: AppIntentApprovalPolicy = .readOnlyAutoApprove
        XCTAssertTrue(require.requiresApproval)
        XCTAssertFalse(readOnly.requiresApproval)
    }

    /// AppIntentToolExecutor.ApprovalPolicy must be a typealias pointing to
    /// AppIntentApprovalPolicy — existing single-executor call sites must keep
    /// compiling unchanged after this rename.
    func testApprovalPolicyTypealiasIsCompatibleWithTopLevelType() {
        let viaTopLevel: AppIntentApprovalPolicy = .requiresUserApproval
        let viaNested: AppIntentToolExecutor<FooIntent>.ApprovalPolicy = .requiresUserApproval
        // Same underlying type — the Bool values must agree.
        XCTAssertEqual(viaTopLevel.requiresApproval, viaNested.requiresApproval)
    }
}

#endif // canImport(AppIntents)
