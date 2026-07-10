import XCTest
@testable import ManifoldHardware

/// Capability-surface tripwires for `BackendCapabilities` (arch-plan 1.3 /
/// api-review-wave2 0.D).
///
/// `BackendCapabilities` has ~25 stored fields and two hand-written
/// "touch every field" surfaces (`union(_:)`, `updating(...)`) plus
/// `CodingKeys`/`encode`/`init(from:)`. Nothing in Swift enforces that a
/// newly added stored field gets threaded through all of them — that's
/// exactly the bug class that let `AnyLanguageModelBackend.loadModel` silently
/// zero 7 of 25 fields for months. This file is the enforcement mechanism:
/// it converts "remember to update N sites" into test truth.
final class BackendCapabilitiesFieldCompletenessTests: XCTestCase {

    /// Every stored property `BackendCapabilities` currently declares.
    /// `Mirror` reflects a *struct's* actual stored fields at runtime — it
    /// does not see computed properties (`contextWindowSize`,
    /// `visibleParameters`, `preferredStructuredOutputSupport`, the deprecated
    /// `streamsToolCallArgumentDeltas` alias), so this list only has to track
    /// storage, matching what `union(_:)`/`updating(...)` actually need to
    /// merge/forward.
    ///
    /// If this test fails because you added a field: also add it to
    /// `BackendCapabilities.union(_:)`'s merge loop, `updating(...)`'s
    /// override parameters, and `CodingKeys`/`init(from:)`/`encode(to:)` —
    /// then extend this list. If you removed a field, remove it from all of
    /// the above, including this list.
    private static let expectedStoredFields: Set<String> = [
        "supportedParameters",
        "maxContextTokens",
        "maxOutputTokens",
        "requiresPromptTemplate",
        "supportsSystemPrompt",
        "supportsStreaming",
        "supportsToolCalling",
        "supportsStructuredOutput",
        "supportsNativeJSONMode",
        "cancellationStyle",
        "supportsTokenCounting",
        "memoryStrategy",
        "isRemote",
        "supportsKVCachePersistence",
        "supportsGrammarConstrainedSampling",
        "supportsThinking",
        "supportsVision",
        "streamsToolCallArguments",
        "supportsParallelToolCalls",
        "supportsGuidedStructuredOutput",
        "supportsStrictSchema",
        "sharesMLXProcessResources",
        "rendersFullPrompt",
        "maxAdvertisedToolCount",
        "toolDialect",
    ]

    func test_fieldCompleteness_mirrorMatchesExpectedList() {
        let mirror = Mirror(reflecting: BackendCapabilities())
        let actualFields = Set(mirror.children.compactMap(\.label))

        let addedButNotTracked = actualFields.subtracting(Self.expectedStoredFields)
        let trackedButRemoved = Self.expectedStoredFields.subtracting(actualFields)

        XCTAssertTrue(
            addedButNotTracked.isEmpty,
            """
            BackendCapabilities gained new stored field(s) not covered by this \
            test's expectedStoredFields list: \(addedButNotTracked.sorted()). \
            Update BackendCapabilities.union(_:), BackendCapabilities.updating(...), \
            and CodingKeys/init(from:)/encode(to:) in Sources/ManifoldHardware/BackendCapabilities.swift, \
            then add the new field name(s) to expectedStoredFields in this test.
            """
        )
        XCTAssertTrue(
            trackedButRemoved.isEmpty,
            """
            BackendCapabilities dropped stored field(s) still listed in this test's \
            expectedStoredFields: \(trackedButRemoved.sorted()). Remove them from \
            union(_:), updating(...), CodingKeys/init(from:)/encode(to:), and this list.
            """
        )
    }
}

/// Behavioral coverage for the two "touch every field" surfaces themselves —
/// not just the field-name tripwire above, but proof that `union(_:)` and
/// `updating(...)` actually merge/forward every field rather than falling
/// back to a default.
final class BackendCapabilitiesUnionAndUpdatingTests: XCTestCase {

    // MARK: - updating(...)

    func test_updating_withNoOverrides_isIdenticalToSelf() {
        let fixture = Self.maximallyNonDefaultFixture()
        XCTAssertEqual(fixture.updating(), fixture)
    }

    func test_updating_overridesOnlyTheNamedField() {
        let fixture = Self.maximallyNonDefaultFixture()
        let updated = fixture.updating(maxContextTokens: 999)

        XCTAssertEqual(updated.maxContextTokens, 999)
        // Every other field must survive untouched — this is the exact
        // property `AnyLanguageModelBackend.loadModel` needed and the
        // fresh-literal rebuild broke.
        var expected = fixture
        expected = BackendCapabilities(
            supportedParameters: expected.supportedParameters,
            maxContextTokens: 999,
            requiresPromptTemplate: expected.requiresPromptTemplate,
            supportsSystemPrompt: expected.supportsSystemPrompt,
            supportsToolCalling: expected.supportsToolCalling,
            supportsStructuredOutput: expected.supportsStructuredOutput,
            supportsNativeJSONMode: expected.supportsNativeJSONMode,
            cancellationStyle: expected.cancellationStyle,
            supportsTokenCounting: expected.supportsTokenCounting,
            memoryStrategy: expected.memoryStrategy,
            maxOutputTokens: expected.maxOutputTokens,
            supportsStreaming: expected.supportsStreaming,
            isRemote: expected.isRemote,
            supportsKVCachePersistence: expected.supportsKVCachePersistence,
            supportsGrammarConstrainedSampling: expected.supportsGrammarConstrainedSampling,
            supportsThinking: expected.supportsThinking,
            supportsVision: expected.supportsVision,
            streamsToolCallArguments: expected.streamsToolCallArguments,
            supportsParallelToolCalls: expected.supportsParallelToolCalls,
            supportsGuidedStructuredOutput: expected.supportsGuidedStructuredOutput,
            supportsStrictSchema: expected.supportsStrictSchema,
            sharesMLXProcessResources: expected.sharesMLXProcessResources,
            rendersFullPrompt: expected.rendersFullPrompt,
            maxAdvertisedToolCount: expected.maxAdvertisedToolCount,
            toolDialect: expected.toolDialect
        )
        XCTAssertEqual(updated, expected)
    }

    func test_updating_canOverrideOptionalFieldToNil() {
        let fixture = BackendCapabilities(maxAdvertisedToolCount: 16)
        XCTAssertEqual(fixture.maxAdvertisedToolCount, 16)

        let cleared = fixture.updating(maxAdvertisedToolCount: .some(nil))
        XCTAssertNil(cleared.maxAdvertisedToolCount)
    }

    // MARK: - union(_:) — the previously-stale fields

    func test_union_orMergesSupportsStrictSchemaAndSharesMLXProcessResources() {
        let a = BackendCapabilities(supportsStrictSchema: false, sharesMLXProcessResources: false)
        let b = BackendCapabilities(supportsStrictSchema: true, sharesMLXProcessResources: true)

        let merged = BackendCapabilities.union([a, b])
        XCTAssertTrue(merged.supportsStrictSchema)
        XCTAssertTrue(merged.sharesMLXProcessResources)
    }

    func test_union_andMergesRendersFullPrompt() {
        // rendersFullPrompt is a fidelity guarantee: the union only holds if
        // EVERY child renders the full prompt, because a caller can't tell
        // which child served a given turn.
        let fullRenderer = BackendCapabilities(rendersFullPrompt: true)
        let partialRenderer = BackendCapabilities(rendersFullPrompt: false)

        XCTAssertFalse(BackendCapabilities.union([fullRenderer, partialRenderer]).rendersFullPrompt)
        XCTAssertTrue(BackendCapabilities.union([fullRenderer, fullRenderer]).rendersFullPrompt)
    }

    func test_union_takesMostRestrictiveMaxAdvertisedToolCount() {
        let unlimited = BackendCapabilities(maxAdvertisedToolCount: nil)
        let cappedAt16 = BackendCapabilities(maxAdvertisedToolCount: 16)
        let cappedAt5 = BackendCapabilities(maxAdvertisedToolCount: 5)

        XCTAssertEqual(BackendCapabilities.union([unlimited, cappedAt16]).maxAdvertisedToolCount, 16)
        XCTAssertEqual(BackendCapabilities.union([cappedAt16, cappedAt5]).maxAdvertisedToolCount, 5)
        XCTAssertNil(BackendCapabilities.union([unlimited, unlimited]).maxAdvertisedToolCount)
    }

    // MARK: - fixture

    private static func maximallyNonDefaultFixture() -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK],
            maxContextTokens: 32_768,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            cancellationStyle: .explicit,
            supportsTokenCounting: true,
            memoryStrategy: .mappable,
            maxOutputTokens: 2_048,
            supportsStreaming: false,
            isRemote: true,
            supportsKVCachePersistence: true,
            supportsGrammarConstrainedSampling: true,
            supportsThinking: true,
            supportsVision: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true,
            supportsGuidedStructuredOutput: true,
            supportsStrictSchema: true,
            sharesMLXProcessResources: true,
            rendersFullPrompt: true,
            maxAdvertisedToolCount: 16,
            toolDialect: ToolCallDialect(family: .hermes, openDelimiter: "<tool_call>", closeDelimiter: "</tool_call>", argEncoding: .json, extractability: .clean)
        )
    }
}

/// Requirement↔field correspondence tripwire: every
/// `GenerationCapabilityRequirement` case must map onto its
/// `BackendCapabilities` field through a single explicit table, and that
/// table must actually match what `BackendCapabilities.satisfies(_:)` does.
///
/// #2153 aligned the one case that used to drift from its field name
/// (`streamingToolCalls` → `streamsToolCallArguments`, matching
/// `BackendCapabilities.streamsToolCallArguments` textually); every case
/// below now names its field exactly.
final class GenerationCapabilityRequirementFieldMappingTests: XCTestCase {

    /// The mapping table. The switch is **exhaustive** (no `default:`
    /// clause): if `GenerationCapabilityRequirement` gains a new case, this
    /// file stops *compiling* until a branch is added here — the strongest
    /// tripwire shape available, stronger than a runtime test failure.
    private static func mappedFieldName(for requirement: GenerationCapabilityRequirement) -> String {
        switch requirement {
        case .toolCalling:                return "supportsToolCalling"
        case .structuredOutput:           return "supportsStructuredOutput"
        case .jsonMode:                   return "supportsNativeJSONMode"
        case .thinking:                   return "supportsThinking"
        case .grammarConstrainedSampling: return "supportsGrammarConstrainedSampling"
        case .parallelToolCalls:          return "supportsParallelToolCalls"
        case .streamsToolCallArguments:   return "streamsToolCallArguments"
        case .kvCachePersistence:         return "supportsKVCachePersistence"
        // Special-shaped: carries an Int, checked against `contextWindowSize`
        // (backed by `maxContextTokens`), not a Bool flag. Verified by
        // test_minContextTokens_satisfiesAgainstContextWindow below instead
        // of the boolean fixture loop.
        case .minContextTokens:           return "maxContextTokens"
        }
    }

    /// Requirement cases whose mapped field is a plain `Bool` settable via
    /// the memberwise init. `minContextTokens` is deliberately excluded —
    /// see the mapping table comment above.
    private static let boolBackedRequirements: [GenerationCapabilityRequirement] = [
        .toolCalling,
        .structuredOutput,
        .jsonMode,
        .thinking,
        .grammarConstrainedSampling,
        .parallelToolCalls,
        .streamsToolCallArguments,
        .kvCachePersistence,
    ]

    private func capabilities(settingFieldNamed name: String, to value: Bool) -> BackendCapabilities {
        BackendCapabilities(
            supportsToolCalling: name == "supportsToolCalling" ? value : false,
            supportsStructuredOutput: name == "supportsStructuredOutput" ? value : false,
            supportsNativeJSONMode: name == "supportsNativeJSONMode" ? value : false,
            supportsKVCachePersistence: name == "supportsKVCachePersistence" ? value : false,
            supportsGrammarConstrainedSampling: name == "supportsGrammarConstrainedSampling" ? value : false,
            supportsThinking: name == "supportsThinking" ? value : false,
            streamsToolCallArguments: name == "streamsToolCallArguments" ? value : false,
            supportsParallelToolCalls: name == "supportsParallelToolCalls" ? value : false
        )
    }

    func test_requirementFieldMapping_everyBoolBackedRequirement_tracksItsMappedField() {
        for requirement in Self.boolBackedRequirements {
            let fieldName = Self.mappedFieldName(for: requirement)

            let satisfying = capabilities(settingFieldNamed: fieldName, to: true)
            XCTAssertTrue(
                satisfying.satisfies(requirement),
                "\(requirement) should be satisfied when \(fieldName) is true — the mapping table or satisfies(_:) drifted."
            )

            let unsatisfying = capabilities(settingFieldNamed: fieldName, to: false)
            XCTAssertFalse(
                unsatisfying.satisfies(requirement),
                "\(requirement) should NOT be satisfied when \(fieldName) is false — the mapping table or satisfies(_:) drifted."
            )
        }
    }

    func test_minContextTokens_satisfiesAgainstContextWindow() {
        let caps = BackendCapabilities(maxContextTokens: 4_096)
        XCTAssertTrue(caps.satisfies(.minContextTokens(4_096)))
        XCTAssertTrue(caps.satisfies(.minContextTokens(2_048)))
        XCTAssertFalse(caps.satisfies(.minContextTokens(4_097)))
    }
}
