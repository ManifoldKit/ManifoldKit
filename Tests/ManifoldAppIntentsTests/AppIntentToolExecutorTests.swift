#if AppIntents
import XCTest
import ManifoldInference
@testable import ManifoldAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Fixtures

/// Happy-path fixture: two required string parameters and one optional.
@available(iOS 26, macOS 26, *)
struct GreetingIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Greet"

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Greeting", description: "Optional salutation override.")
    var greeting: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.name = try c.decode(String.self, forKey: .name)
        self.greeting = try c.decodeIfPresent(String.self, forKey: .greeting)
    }

    private enum CodingKeys: String, CodingKey {
        case name, greeting
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let salutation = greeting ?? "Hello"
        return .result(value: "\(salutation), \(name)")
    }
}

/// Validation fixture: throws on empty input so we can exercise the error path.
@available(iOS 26, macOS 26, *)
struct ValidatingIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Validate"

    @Parameter(title: "Value")
    var value: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.value = try c.decode(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }

    struct EmptyValueError: LocalizedError {
        var errorDescription: String? { "value must not be empty" }
    }

    func perform() async throws -> some IntentResult {
        if value.isEmpty {
            throw EmptyValueError()
        }
        return .result()
    }
}

/// Authorisation fixture: throws an error whose domain matches the
/// permission-denied heuristic so the executor classifies it correctly.
@available(iOS 26, macOS 26, *)
struct UnauthorizedIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Unauthorized"

    @Parameter(title: "Resource")
    var resource: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.resource = try c.decode(String.self, forKey: .resource)
    }

    private enum CodingKeys: String, CodingKey { case resource }

    func perform() async throws -> some IntentResult {
        let error = NSError(
            domain: "com.manifold.test.AuthorizationDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Authorization required for \(resource)"]
        )
        throw error
        // Unreachable — present so the opaque return type can be inferred.
        return .result()
    }
}

/// Multi-type fixture: covers Int, Double, Bool, Date, URL, and Optional in
/// one shot so the schema reflection path is exercised end-to-end.
@available(iOS 26, macOS 26, *)
struct WideIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Wide"

    @Parameter(title: "Count")
    var count: Int

    @Parameter(title: "Ratio")
    var ratio: Double

    @Parameter(title: "Flag")
    var flag: Bool

    @Parameter(title: "When")
    var when: Date

    @Parameter(title: "Link")
    var link: URL

    @Parameter(title: "Note")
    var note: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.count = try c.decode(Int.self, forKey: .count)
        self.ratio = try c.decode(Double.self, forKey: .ratio)
        self.flag = try c.decode(Bool.self, forKey: .flag)
        self.when = try c.decode(Date.self, forKey: .when)
        self.link = try c.decode(URL.self, forKey: .link)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case count, ratio, flag, when, link, note
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: count)
    }
}

/// Date-decoding fixture: one required `Date` parameter so we can verify that
/// `execute(arguments:)` honours the ISO-8601 contract its synthesised schema
/// advertises.
@available(iOS 26, macOS 26, *)
struct DateIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Date"

    @Parameter(title: "When")
    var when: Date

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.when = try c.decode(Date.self, forKey: .when)
    }

    private enum CodingKeys: String, CodingKey { case when }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // ISO-8601 round-trip so the test can assert on a stable string.
        let formatter = ISO8601DateFormatter()
        return .result(value: formatter.string(from: when))
    }
}

/// Phantom-storage fixture: one `@Parameter` field plus an unrelated stored
/// property the schema builder must NOT publish.
@available(iOS 26, macOS 26, *)
struct PhantomStorageIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Phantom"

    @Parameter(title: "Real")
    var real: String

    // Plain stored property — must not show up in the synthesised schema.
    private var cache: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.real = try c.decode(String.self, forKey: .real)
    }

    private enum CodingKeys: String, CodingKey { case real }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        _ = cache  // silence "never read" warning
        return .result(value: real)
    }
}

/// Pure-dialog fixture: `ProvidesDialog` with no `ReturnsValue` payload.
@available(iOS 26, macOS 26, *)
struct PureDialogIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "PureDialog"

    @Parameter(title: "Subject")
    var subject: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.subject = try c.decode(String.self, forKey: .subject)
    }

    private enum CodingKeys: String, CodingKey { case subject }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: "Spoken about \(subject)"))
    }
}

/// Compound fixture: `ReturnsValue<String> & ProvidesDialog` with the value
/// distinct from the dialog text, so the two fields are independently
/// observable.
@available(iOS 26, macOS 26, *)
struct CompoundDialogIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "CompoundDialog"

    @Parameter(title: "Topic")
    var topic: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.topic = try c.decode(String.self, forKey: .topic)
    }

    private enum CodingKeys: String, CodingKey { case topic }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        .result(
            value: "structured-\(topic)",
            dialog: IntentDialog(stringLiteral: "Spoken-\(topic)")
        )
    }
}

/// Title/default-emission fixture: covers the schema-decoration code path
/// that lifts `@Parameter(title:)` into the JSON-Schema `description` field
/// and `@Parameter(default:)` into the `default` field.
@available(iOS 26, macOS 26, *)
struct DecoratedIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Decorated"

    @Parameter(title: "Display Name", default: "World")
    var name: String

    @Parameter(title: "Count", default: 5)
    var count: Int

    @Parameter(title: "Untouched")
    var untouched: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.name = try c.decode(String.self, forKey: .name)
        self.count = try c.decode(Int.self, forKey: .count)
        self.untouched = try c.decode(String.self, forKey: .untouched)
    }

    private enum CodingKeys: String, CodingKey { case name, count, untouched }

    func perform() async throws -> some IntentResult { .result() }
}

/// Collection-parameter fixture: drives the `[T]` / `Set<T>` schema emission
/// path. Includes an optional array so the optional-vs-required pairing is
/// exercised in one fixture.
@available(iOS 26, macOS 26, *)
struct CollectionIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Collection"

    @Parameter(title: "Tags")
    var tags: [String]

    @Parameter(title: "Counts")
    var counts: [Int]

    @Parameter(title: "Unique")
    var unique: Set<String>

    @Parameter(title: "Maybe Tags")
    var maybeTags: [String]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.tags = try c.decode([String].self, forKey: .tags)
        self.counts = try c.decode([Int].self, forKey: .counts)
        self.unique = try c.decode(Set<String>.self, forKey: .unique)
        self.maybeTags = try c.decodeIfPresent([String].self, forKey: .maybeTags)
    }

    private enum CodingKeys: String, CodingKey { case tags, counts, unique, maybeTags }

    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Tests

@available(iOS 26, macOS 26, *)
final class AppIntentToolExecutorTests: XCTestCase {

    // MARK: helpers

    /// Returns the `type` field of a property-shaped schema object, or nil
    /// if the schema isn't an object or doesn't carry one. Used to keep
    /// shape-focused tests robust against additive schema fields
    /// (descriptions, defaults, etc.).
    private func propertyType(_ value: JSONSchemaValue?) -> String? {
        guard case .object(let dict) = value, case .string(let t) = dict["type"] else { return nil }
        return t
    }

    private func propertyFormat(_ value: JSONSchemaValue?) -> String? {
        guard case .object(let dict) = value, case .string(let f) = dict["format"] else { return nil }
        return f
    }

    // MARK: definition synthesis

    func testDefinitionDerivesNameFromIntentType() {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        XCTAssertEqual(executor.definition.name, "greeting_intent")
    }

    func testDefinitionUsesCustomDescription() {
        let executor = AppIntentToolExecutor(GreetingIntent.self, description: "Greets a person.")
        XCTAssertEqual(executor.definition.description, "Greets a person.")
    }

    func testSchemaIncludesRequiredAndOptionalFields() {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        guard case .object(let root) = executor.definition.parameters else {
            return XCTFail("schema root must be an object")
        }

        XCTAssertEqual(root["type"], .string("object"))

        guard case .object(let properties) = root["properties"] else {
            return XCTFail("schema must have an object `properties` field")
        }
        // Asserting on `type` only keeps this test focused on
        // required-vs-optional placement; the title-as-description emission
        // is exercised in `testSchemaEmitsParameterTitleAsDescription`.
        XCTAssertEqual(propertyType(properties["name"]), "string")
        XCTAssertEqual(propertyType(properties["greeting"]), "string")

        guard case .array(let required) = root["required"] else {
            return XCTFail("schema must declare `required`")
        }
        XCTAssertEqual(required, [.string("name")], "optional `greeting` must not appear in `required`")
    }

    func testSchemaCoversCommonPrimitiveTypes() {
        let executor = AppIntentToolExecutor(WideIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        XCTAssertEqual(propertyType(properties["count"]), "integer")
        XCTAssertEqual(propertyType(properties["ratio"]), "number")
        XCTAssertEqual(propertyType(properties["flag"]), "boolean")
        XCTAssertEqual(propertyType(properties["when"]), "string")
        XCTAssertEqual(propertyFormat(properties["when"]), "date-time")
        XCTAssertEqual(propertyType(properties["link"]), "string")
        XCTAssertEqual(propertyFormat(properties["link"]), "uri")
        // Optional → still in `properties`, but missing from `required`.
        XCTAssertEqual(propertyType(properties["note"]), "string")

        guard case .array(let required) = root["required"] else {
            return XCTFail("schema must declare `required`")
        }
        let requiredNames = required.compactMap { value -> String? in
            if case .string(let s) = value { return s } else { return nil }
        }
        XCTAssertFalse(requiredNames.contains("note"), "optional fields must not be required")
        XCTAssertTrue(requiredNames.contains("count"))
        XCTAssertTrue(requiredNames.contains("ratio"))
        XCTAssertTrue(requiredNames.contains("flag"))
        XCTAssertTrue(requiredNames.contains("when"))
        XCTAssertTrue(requiredNames.contains("link"))
    }

    // MARK: execution

    func testExecuteHappyPathSerialisesResult() async throws {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        let args = JSONSchemaValue.object([
            "name": .string("Ada"),
            "greeting": .string("Salut"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind, "happy path must not surface an error kind")
        XCTAssertTrue(
            result.content.contains("Salut") && result.content.contains("Ada"),
            "result body must include intent output, got \(result.content)"
        )
    }

    func testExecuteWithMissingRequiredFieldReturnsInvalidArguments() async throws {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        // No `name` key → JSONDecoder will throw a keyNotFound error.
        let args = JSONSchemaValue.object([:])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertTrue(result.content.contains("AppIntent arguments"))
    }

    func testExecuteSurfacesIntentValidationErrorAsPermanent() async throws {
        let executor = AppIntentToolExecutor(ValidatingIntent.self)
        let args = JSONSchemaValue.object([
            "value": .string(""),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertTrue(result.content.contains("must not be empty"))
    }

    func testExecuteDetectsAuthorizationFailure() async throws {
        let executor = AppIntentToolExecutor(UnauthorizedIntent.self)
        let args = JSONSchemaValue.object([
            "resource": .string("camera"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertEqual(
            result.errorKind,
            .permissionDenied,
            "authorisation-domain errors must surface as .permissionDenied"
        )
        XCTAssertTrue(result.content.contains("Authorization required"))
    }

    func testExecuteDecodesISO8601DateArguments() async throws {
        let executor = AppIntentToolExecutor(DateIntent.self)
        // The synthesised schema advertises `Date` as a string with
        // `format: date-time`, so the executor must treat the argument as
        // ISO-8601. A vanilla `JSONDecoder` would default to
        // `secondsSince2001` and reject this string.
        let iso = "2026-04-26T12:34:56Z"
        let args = JSONSchemaValue.object([
            "when": .string(iso),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(
            result.errorKind,
            "ISO-8601 date arguments must decode without error, got \(String(describing: result.errorKind)): \(result.content)"
        )
        // `perform()` round-trips the date back through the same formatter,
        // so equality on the input string proves the decode produced the
        // expected `Date`.
        XCTAssertTrue(
            result.content.contains(iso),
            "expected round-tripped ISO-8601 string in result body, got \(result.content)"
        )
    }

    // MARK: schema hygiene

    func testSchemaSkipsNonParameterStoredProperties() {
        let executor = AppIntentToolExecutor(PhantomStorageIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        XCTAssertEqual(
            Set(properties.keys),
            ["real"],
            "only @Parameter-wrapped properties may appear in the synthesised schema; got \(properties.keys.sorted())"
        )
    }

    func testExecutorIsToolExecutorConformant() {
        // Compile-time conformance check + runtime dispatch through the
        // protocol existential, mirroring how ToolRegistry will see the
        // executor in production.
        let executor: any ToolExecutor = AppIntentToolExecutor(GreetingIntent.self)
        XCTAssertEqual(executor.definition.name, "greeting_intent")
        XCTAssertTrue(executor.requiresApproval, "AppIntent executors require approval by default")
        XCTAssertFalse(executor.supportsConcurrentDispatch, "default sequential dispatch")
    }

    // MARK: dialog channel

    // Documented limitation of the public-API extraction (PR #1385 follow-up):
    // on iOS 26 / macOS 26 `IntentDialog` stores its text inside a private
    // `LNStaticDeferredLocalizedString` ObjC class reachable only via KVC,
    // which we deliberately do not call. `extractDialog` therefore returns
    // `nil` for these fixtures, and content falls back to the structured
    // `IntentResultContainer` dump. The next time Apple promotes the dialog
    // storage to a public surface (e.g. `IntentDialog.full` returning a
    // `LocalizedStringResource`), these tests should be flipped to assert
    // the actual spoken text. Tracked in code comments rather than an issue
    // per CLAUDE.md's "no follow-up issues" hygiene rule.

    func testPureDialogIntentExtractionFallsThroughOnPublicAPI() async throws {
        let executor = AppIntentToolExecutor(PureDialogIntent.self)
        let args = JSONSchemaValue.object(["subject": .string("weather")])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind)
        // Public-only extraction can't reach `LNStaticDeferredLocalizedString`
        // storage on iOS 26 / macOS 26 — documented contract is `nil`.
        XCTAssertNil(
            result.dialog,
            "public-API dialog extraction is expected to return nil on iOS 26 / macOS 26; got \(String(describing: result.dialog))"
        )
        // With dialog == nil the executor falls through to the structured
        // serialisation path, which `String(describing:)`s the
        // `IntentResultContainer`. We assert only that the spoken text
        // appears *somewhere* in the dump — that proves the IntentDialog
        // payload survived to the content channel even when extraction
        // couldn't pluck it out cleanly.
        XCTAssertTrue(
            result.content.contains("Spoken about weather"),
            "pure-dialog content fallback must still surface the IntentDialog text in the structured dump; got \(result.content)"
        )
    }

    func testCompoundDialogIntentSplitsValueAndDialog() async throws {
        let executor = AppIntentToolExecutor(CompoundDialogIntent.self)
        let args = JSONSchemaValue.object(["topic": .string("alpha")])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind)
        // Public-only extraction returns nil for the same reason as the
        // pure-dialog fixture: the IntentDialog storage is private.
        XCTAssertNil(
            result.dialog,
            "public-API dialog extraction is expected to return nil on iOS 26 / macOS 26; got \(String(describing: result.dialog))"
        )
        // The ReturnsValue<String> path is independent of dialog extraction
        // — `extractReturnsValue` reads the public `value` slot via Mirror,
        // so the JSON-encoded structured value still reaches content.
        XCTAssertTrue(
            result.content.contains("structured-alpha"),
            "content must carry the JSON-encoded ReturnsValue, got \(result.content)"
        )
    }

    func testPlainIntentLeavesDialogNil() async throws {
        let executor = AppIntentToolExecutor(GreetingIntent.self)
        let args = JSONSchemaValue.object([
            "name": .string("Ada"),
            "greeting": .string("Salut"),
        ])

        let result = try await executor.execute(arguments: args)

        XCTAssertNil(result.errorKind)
        XCTAssertNil(
            result.dialog,
            "intents without ProvidesDialog must leave dialog nil; got \(String(describing: result.dialog))"
        )
    }

    func testToolResultCodableRoundTripPreservesDialog() throws {
        let original = ToolResult(
            callId: "abc",
            content: "structured",
            errorKind: nil,
            dialog: "spoken"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.dialog, "spoken")
    }

    func testToolResultCodableOmitsDialogKeyWhenNil() throws {
        let result = ToolResult(callId: "abc", content: "structured", errorKind: nil)
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            json.contains("\"dialog\""),
            "nil dialog must be omitted by encodeIfPresent to keep the pre-dialog wire shape; got \(json)"
        )
        // Sanity: a non-nil dialog DOES appear, proving the assertion above
        // is meaningful (i.e. the key isn't simply always missing).
        let withDialog = ToolResult(callId: "abc", content: "structured", errorKind: nil, dialog: "spoken")
        let dialogJSON = try XCTUnwrap(String(data: JSONEncoder().encode(withDialog), encoding: .utf8))
        XCTAssertTrue(dialogJSON.contains("\"dialog\""))
    }

    // MARK: private-API tripwire

    /// Static guard: the executor source file must NOT reference private
    /// AppIntents framework internals (KVC-based dialog extraction, the
    /// `LNStaticDeferredLocalizedString` private class, etc.). Reintroducing
    /// any of these strings would walk back the public-only extraction
    /// commitment from PR #1385.
    func testExecutorSourceDoesNotReferencePrivateAppIntentsAPI() throws {
        // Navigate from this test file's path to the executor source.
        // `#filePath` is the absolute path under SwiftPM test runs, so this
        // resolves stably without bundle plumbing.
        let testFile = URL(fileURLWithPath: #filePath)
        let executorFile = testFile
            .deletingLastPathComponent()              // ManifoldAppIntentsTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // package root
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldAppIntents")
            .appendingPathComponent("AppIntentToolExecutor.swift")

        let source: String
        do {
            source = try String(contentsOf: executorFile, encoding: .utf8)
        } catch {
            // FIXME: if `#filePath` ever stops resolving to a real on-disk
            // path under SwiftPM test runs, downgrade this to a skipped
            // diagnostic rather than a flaky failure.
            throw XCTSkip("could not read executor source at \(executorFile.path): \(error)")
        }

        let banned = ["LNStatic", "value(forKey:", "valueForKey", "class_copyPropertyList", "class_copyIvarList"]
        for needle in banned {
            XCTAssertFalse(
                source.contains(needle),
                "AppIntentToolExecutor.swift must not contain \"\(needle)\" — private-API dialog extraction was removed in PR #1385 and must not be reintroduced."
            )
        }
    }

    func testReadOnlyApprovalPolicyCanOptOutOfPrompt() {
        let executor: any ToolExecutor = AppIntentToolExecutor(
            GreetingIntent.self,
            approvalPolicy: .readOnlyAutoApprove
        )
        XCTAssertFalse(executor.requiresApproval, "read-only AppIntent tools can be deliberately auto-approved")
    }

    // MARK: title + default emission

    func testSchemaEmitsParameterTitleAsDescription() {
        let executor = AppIntentToolExecutor(DecoratedIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"],
              case .object(let nameField) = properties["name"]
        else {
            return XCTFail("schema must contain a `name` property object")
        }
        XCTAssertEqual(
            nameField["description"],
            .string("Display Name"),
            "schema must surface @Parameter(title:) as the per-property description"
        )
    }

    func testSchemaEmitsParameterDefaultValue() {
        let executor = AppIntentToolExecutor(DecoratedIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"],
              case .object(let nameField) = properties["name"],
              case .object(let countField) = properties["count"]
        else {
            return XCTFail("schema must contain `name` and `count` property objects")
        }
        XCTAssertEqual(
            nameField["default"],
            .string("World"),
            "string defaults must round-trip through the schema as JSON strings"
        )
        // Number defaults: JSONSchemaValue stores all numbers as Double, so
        // `5` arrives as `.number(5.0)`. We don't care about the boxing —
        // only that the value made it through.
        XCTAssertEqual(
            countField["default"],
            .number(5),
            "integer defaults must surface in the schema"
        )
    }

    func testSchemaOmitsDefaultAndDescriptionWhenNoneProvided() {
        let executor = AppIntentToolExecutor(DecoratedIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"],
              case .object(let untouched) = properties["untouched"]
        else {
            return XCTFail("schema must contain `untouched` property object")
        }
        XCTAssertNil(
            untouched["default"],
            "a parameter without a default must not carry a `default` field"
        )
        // `Untouched` is still a title on the wrapper — verify it shows up
        // even when no default exists; otherwise the decoration path would
        // be silently skipping fields.
        XCTAssertEqual(untouched["description"], .string("Untouched"))
    }

    // MARK: collection support

    func testSchemaEmitsArraysWithItemTypes() {
        let executor = AppIntentToolExecutor(CollectionIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        guard case .object(let tagsSchema) = properties["tags"] else {
            return XCTFail("tags must produce an object schema")
        }
        XCTAssertEqual(tagsSchema["type"], .string("array"))
        XCTAssertEqual(
            tagsSchema["items"],
            .object(["type": .string("string")]),
            "[String] must emit items of type string"
        )

        guard case .object(let countsSchema) = properties["counts"] else {
            return XCTFail("counts must produce an object schema")
        }
        XCTAssertEqual(countsSchema["type"], .string("array"))
        XCTAssertEqual(
            countsSchema["items"],
            .object(["type": .string("integer")]),
            "[Int] must emit items of type integer"
        )

        guard case .object(let uniqueSchema) = properties["unique"] else {
            return XCTFail("unique must produce an object schema")
        }
        XCTAssertEqual(uniqueSchema["type"], .string("array"))
        XCTAssertEqual(
            uniqueSchema["items"],
            .object(["type": .string("string")]),
            "Set<String> must emit items of type string"
        )
    }

    func testSchemaTreatsOptionalArrayAsArrayButNotRequired() {
        let executor = AppIntentToolExecutor(CollectionIntent.self)
        guard case .object(let root) = executor.definition.parameters,
              case .object(let properties) = root["properties"]
        else {
            return XCTFail("schema root must be an object with properties")
        }

        // The optional-of-array must still emit array shape — only the
        // required-membership is affected.
        guard case .object(let maybe) = properties["maybeTags"] else {
            return XCTFail("maybeTags must produce an object schema")
        }
        XCTAssertEqual(maybe["type"], .string("array"))
        XCTAssertEqual(maybe["items"], .object(["type": .string("string")]))

        guard case .array(let required) = root["required"] else {
            return XCTFail("schema must declare `required`")
        }
        let requiredNames = required.compactMap { value -> String? in
            if case .string(let s) = value { return s } else { return nil }
        }
        XCTAssertFalse(
            requiredNames.contains("maybeTags"),
            "optional array parameter must not appear in `required`"
        )
        XCTAssertTrue(requiredNames.contains("tags"), "non-optional array must be required")
        XCTAssertTrue(requiredNames.contains("counts"))
        XCTAssertTrue(requiredNames.contains("unique"))
    }

    // MARK: locale-safe auth classification

    func testAuthDetectionRecognisesAppIntentsAuthorizationDomain() {
        let error = NSError(
            domain: "AppIntentsAuthorizationErrorDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "anything in any language"]
        )
        XCTAssertTrue(
            AppIntentToolExecutor<GreetingIntent>.looksLikeAuthorizationFailure(error),
            "errors in the AppIntents authorisation domain must classify as auth failures"
        )
    }

    func testAuthDetectionRecognisesLAErrorDomain() {
        let error = NSError(
            domain: "com.apple.LocalAuthentication",
            code: -4, // LAError.systemCancel
            userInfo: [:]
        )
        XCTAssertTrue(
            AppIntentToolExecutor<GreetingIntent>.looksLikeAuthorizationFailure(error),
            "LocalAuthentication errors (Face ID / Touch ID) must classify as auth failures"
        )
    }

    func testAuthDetectionIgnoresEnglishDescriptionOnUnrelatedDomain() {
        // The hostile case: an unrelated framework throws an error whose
        // English description happens to read "permission denied". The
        // previous heuristic would have misclassified this; the new one
        // ignores `localizedDescription` entirely and only sees the domain.
        let error = NSError(
            domain: "com.example.NetworkError",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        XCTAssertFalse(
            AppIntentToolExecutor<GreetingIntent>.looksLikeAuthorizationFailure(error),
            "domain-unrelated errors must NOT be classified as auth even if their English description suggests it — locale safety"
        )
    }

    func testAuthDetectionMatchesDomainSubstringFallback() {
        // Third-party domains that follow the convention still match —
        // domain identity is locale-safe even with substring matching
        // because domain strings are developer-authored API surface.
        let error = NSError(
            domain: "com.example.PermissionDeniedError",
            code: 1,
            userInfo: [:]
        )
        XCTAssertTrue(
            AppIntentToolExecutor<GreetingIntent>.looksLikeAuthorizationFailure(error),
            "third-party domains with `permission` / `authorisation` substring should still match"
        )
    }
}

#endif // canImport(AppIntents)
#endif
