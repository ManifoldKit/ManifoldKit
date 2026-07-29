@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldContractTestSupport

/// Coverage for the ``ImageGenerationToolSource`` not-configured alignment
/// (#2128 item E): before this fix the image source folded not-configured
/// into the same blanket `.transient` catch as genuine runtime failures, so
/// the model was told the failure was retryable when no image backend was
/// wired at all. Mirrors the #2356 `VideoGenerationToolSource` fix — a
/// truthful `.permanent` for not-configured, `.transient` reserved for real
/// runtime failures.
@MainActor
final class ImageGenerationToolSourceTests: XCTestCase, SessionToolSourceContract {

    // MARK: - SessionToolSourceContract
    //
    // ISOLATION: `makeSource()` is a nonisolated protocol requirement, but
    // this class is `@MainActor` (pre-existing, needed for the rest of this
    // file's `@MainActor` `ChatViewModel` bodies) and `ImageGenerationToolSource`
    // needs a `@MainActor` `ChatViewModel`. Calling the contract's nonisolated
    // `assertSessionToolSource_*()` helpers directly from an ordinary
    // `@MainActor` test method genuinely does not compile — confirmed with a
    // from-scratch minimal reproduction (a two-file SwiftPM package,
    // `swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`, no other
    // ManifoldKit code involved) that hits the identical diagnostic:
    //
    //   error: sending 'self' risks causing data races [#SendingRisksDataRace]
    //   note: sending main actor-isolated 'self' to nonisolated instance
    //   method 'assertStable()' risks causing data races between nonisolated
    //   and main actor-isolated uses
    //
    // `self` is a non-Sendable `@MainActor`-isolated `XCTestCase`, so calling
    // a nonisolated instance method (the protocol extension) from an
    // `@MainActor`-isolated call site requires sending that isolated `self`
    // across the boundary. `nonisolated` on the `test_contract_*` wrapper
    // methods below IS load-bearing: removing it (confirmed in the same
    // minimal repro, with this exact lock-based `makeSource()` kept
    // unchanged) reproduces the identical error. Fix: the `test_contract_*`
    // wrapper methods are `nonisolated` per-member overrides so `self` isn't
    // sent across an isolation boundary at that call site, and the
    // actually-`@MainActor`-built source is handed across via an
    // `OSAllocatedUnfairLock` populated once in `setUp()` — real mutual
    // exclusion, not `@unchecked Sendable` or `Task.detached`.
    //
    // UserDefaults: `setUp()` runs before every test in this class, so its
    // `ChatViewModel` must not default to `.standard` (AGENTS.md's
    // UserDefaults-injection rule, bitten twice: #734/#761) — a per-instance
    // suite name avoids cross-test / cross-suite pollution under
    // `swift test --parallel`.
    private let sourceStorage = OSAllocatedUnfairLock<(any SessionToolSource)?>(initialState: nil)

    private func makeContractViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "ImageGenerationToolSourceTests-\(UUID().uuidString)")!
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        let source = ImageGenerationToolSource(viewModel: makeContractViewModel())
        sourceStorage.withLock { $0 = source }
    }

    nonisolated func makeSource() -> any SessionToolSource {
        guard let source = sourceStorage.withLock({ $0 }) else {
            fatalError("ImageGenerationToolSourceTests.makeSource() called before setUp() populated the source — a test-harness ordering bug, not a runtime condition a real caller can hit.")
        }
        return source
    }

    nonisolated func test_contract_toolDefinitionsStableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    nonisolated func test_contract_allowedToolNamesDefaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // MARK: - Deliberate non-adoption: assertSessionToolSource_resolve_unknownTool_throws()
    //
    // Not wired up. `ImageGenerationToolSource.resolve` (`Sources/ManifoldUI/Tools/ImageGenerationToolSource.swift:48-50`)
    // does not throw for an unadvertised tool name — it returns
    // `ToolResult(callId:content:errorKind: .unknownTool)`. This is not the
    // "fabricated result for a tool it did not advertise" the contract's doc
    // warns about: `ToolResult.errorKind` is a first-class, localized error
    // channel (`ToolTypes.swift:451`, mapping `.unknownTool` to "This tool
    // isn't available."), and `SessionToolSourceExecutor` (`SessionToolSourceExecutor.swift:53-66`)
    // always constructs sources with an advertised `definition` and forwards
    // the result unexamined — so an actual unadvertised-name call is not a
    // reachable production path for this executor. It's a genuine encoding
    // split across `SessionToolSource` conformers (`SkillToolSource` /
    // `HandoffToolSource` throw; the three UI tool sources return a
    // structured error), not a defect this PR should paper over by forcing
    // the throw-based assertion. `test_resolve_unknownTool_stillReturnsUnknownToolError`
    // below already pins this via a literal tool name; this one additionally
    // pins it through the shared contract fixtures for parity with the
    // other two adopters:
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
    // `@MainActor` construction problem the lock exists to solve. It does
    // not weaken the two assertions actually adopted above (neither depends
    // on cross-instance freshness), but a future assertion that does would
    // need this file's `makeSource()` revisited.

    /// Bare in-memory `MessageStore` — only exists to satisfy
    /// `ImageGenerationRuntime`'s initializer; the configured-but-no-session
    /// test fails at the `.noActiveConversation` precondition before reaching
    /// a real insert.
    private final class StubMessageStore: MessageStore, @unchecked Sendable {
        func insertMessage(_ message: ChatMessage) async throws {}
        func updateMessage(_ message: ChatMessage) async throws {}
        func deleteMessage(_ messageID: UUID) async throws {}
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] { [] }
        func deleteMessages(for sessionID: UUID) async throws {}
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    private func makeConfiguredViewModel() -> ChatViewModel {
        let vm = ChatViewModel()
        vm.configure(imageRuntime: ImageGenerationRuntime(
            service: ImageGenerationService(),
            messageStore: StubMessageStore()
        ))
        return vm
    }

    // MARK: - Not configured: permanent, not transient

    func test_resolve_notConfigured_returnsPermanentError() async throws {
        let vm = ChatViewModel()
        XCTAssertNil(vm.imageRuntime, "Precondition: no ImageGenerationRuntime installed")
        let source = ImageGenerationToolSource(viewModel: vm)

        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .permanent,
            "Not-configured must be a permanent (non-retryable) tool error, not .transient")
        XCTAssertFalse(
            result.content.lowercased().contains("generation started"),
            "Must not claim generation started when no image backend is configured: \(result.content)"
        )
    }

    // MARK: - Argument short-circuits (unchanged, pinned so the new guard didn't reorder them)

    func test_resolve_unknownTool_stillReturnsUnknownToolError() async throws {
        let source = ImageGenerationToolSource(viewModel: ChatViewModel())
        let result = try await source.resolve(
            toolName: "not_a_real_tool",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    func test_resolve_missingPrompt_stillReturnsInvalidArgumentsError() async throws {
        let source = ImageGenerationToolSource(viewModel: ChatViewModel())
        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )
        XCTAssertEqual(result.errorKind, .invalidArguments)
    }

    // MARK: - Configured but a genuine runtime failure: transient

    /// With a runtime installed but no active session, `generateImage` throws
    /// `.noActiveConversation` — a genuine runtime failure that must stay
    /// `.transient`, distinct from the not-configured `.permanent` above.
    func test_resolve_configuredButNoActiveConversation_returnsTransientError() async throws {
        let vm = makeConfiguredViewModel()
        XCTAssertNotNil(vm.imageRuntime, "Precondition: runtime IS configured, exercising the catch path, not the preflight")
        XCTAssertNil(vm.activeSessionID, "Precondition: no active session — generateImage() throws .noActiveConversation")

        let source = ImageGenerationToolSource(viewModel: vm)
        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .transient,
            "A genuine runtime failure (no active session) must remain .transient")
    }
}
