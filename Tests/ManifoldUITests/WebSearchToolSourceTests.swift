@preconcurrency import XCTest
import Foundation
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldContractTestSupport

/// Exercises ``WebSearchToolSource`` against the shared
/// ``SessionToolSourceContract`` mixin. Construction pattern mirrors
/// `ChatViewModelWebSearchTests`.
final class WebSearchToolSourceTests: XCTestCase, SessionToolSourceContract {

    // `static` (not an instance method): `setUp()` builds the source inside
    // a `MainActor.run` closure from a nonisolated context, and a self-bound
    // instance method call there would capture `self` — a non-Sendable,
    // task-isolated `XCTestCase` reused later by the test methods — into
    // that main-actor-isolated closure, which Swift 6 rejects as a data-race
    // risk. A `static` helper touches no instance state, so no `self`
    // capture is needed.
    @MainActor
    private static func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "WebSearchToolSourceTests-\(UUID().uuidString)")!
        )
    }

    // MARK: - SessionToolSourceContract
    //
    // `makeSource()` is a nonisolated protocol requirement, but
    // `WebSearchToolSource` needs a `@MainActor` `ChatViewModel`. This class
    // carries no `@MainActor` annotation of its own — unlike
    // `ImageGenerationToolSourceTests`/`VideoGenerationToolSourceTests`,
    // which retain a pre-existing `@MainActor` on the class for their other
    // (non-contract) tests — so the shape here matches the existing
    // adopter (`HandoffToolSourceContractTests`):
    // build the `@MainActor`-isolated source once in `setUp()` via
    // `MainActor.run`, store it, and hand it back synchronously from the
    // nonisolated `makeSource()`. `setUp()` and the test method run
    // sequentially on the same XCTestCase instance, so there is no
    // concurrent access to `stored` to guard against.
    private var stored: (any SessionToolSource)?

    override func setUp() async throws {
        try await super.setUp()
        stored = await MainActor.run { WebSearchToolSource(viewModel: Self.makeViewModel()) }
    }

    func makeSource() -> any SessionToolSource { stored! }

    func test_contract_toolDefinitionsStableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    func test_contract_allowedToolNamesDefaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // MARK: - Deliberate non-adoption: assertSessionToolSource_resolve_unknownTool_throws()
    //
    // Not wired up. `WebSearchToolSource.resolve` (`Sources/ManifoldUI/Tools/WebSearchToolSource.swift:51-53`)
    // does not throw for an unadvertised tool name — it returns
    // `ToolResult(callId:content:errorKind: .unknownTool)`. This is not the
    // "fabricated result for a tool it did not advertise" the contract's doc
    // warns about: `ToolResult.errorKind` is a first-class, localized error
    // channel (`ToolTypes.swift:451`, mapping `.unknownTool` to "This tool
    // isn't available."), and `SessionToolSourceExecutor` (`SessionToolSourceExecutor.swift:53-66`)
    // always constructs sources with an advertised `definition` and forwards
    // the result unexamined — so an actual unadvertised-name call is not a
    // reachable production path for this executor. It's a genuine encoding
    // split across `SessionToolSource` conformers (`HandoffToolSource`
    // throws; the three UI tool sources return a structured error), not a
    // defect this PR should paper over by forcing the throw-based assertion.
    // Pinned instead as the actual behavior:
    func test_resolve_unadvertisedToolName_returnsUnknownToolErrorInsteadOfThrowing() async throws {
        let source = makeSource()
        let session = makeSession()
        let result = try await source.resolve(
            toolName: "__contract_unadvertised_\(UUID().uuidString)",
            arguments: "{}",
            session: session
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    // MARK: - SessionToolSourceContract.makeSource() docstring deviation
    //
    // `SessionToolSourceContract.makeSource()` documents "Returns a fresh,
    // fully-configured source for each assertion call." This adopter
    // deliberately returns the same `setUp()`-built instance for every call
    // within a test method rather than constructing fresh per call: building
    // fresh from the nonisolated `makeSource()` would reintroduce the
    // `@MainActor` construction problem this file exists to solve. It does
    // not weaken the two assertions actually adopted above (neither depends
    // on cross-instance freshness), but a future assertion that does would
    // need this file's `makeSource()` revisited.
}
