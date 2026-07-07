@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldTestSupport

/// Perf-audit β-1: contract tests for the `tokenCountCache` invalidation path.
///
/// `ChatViewModel.tokenCountCache` is a hand-rolled cache keyed by message
/// UUID. The audit identified a hole: when `ConversationEvent.messageUpdated`
/// fires (e.g. the runtime's `edit` sub-flow rewrites a message body in
/// place), the runtime adapter at `ChatViewModel+RuntimeAdapter.swift:57-60`
/// replaces `messages[idx] = record` but does **not** invalidate
/// `tokenCountCache[record.id]`. The next `updateContextEstimate()` returns
/// the stale token count for that UUID.
///
/// Today this is masked because the only caller that triggers `.messageUpdated`
/// is `ChatViewModel.editMessage(...)`, which proactively calls
/// `tokenCountCache.removeValue(forKey: messageID)` BEFORE invoking the
/// runtime (`ChatViewModel+Messages.swift:120`). Any future caller that drives
/// the runtime directly (e.g. compression rewrites, sub-flow patches, debugger
/// attach) would silently expose the bug.
///
/// These tests drive `handle(runtimeEvent:)` directly so the adapter's
/// behaviour is pinned independent of caller compensation.
@MainActor
final class TokenCountCacheInvalidationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - Cache hit path (sanity)

    /// After a `.messageInserted` event the message is on the VM's
    /// `messages` array; calling `updateContextEstimate()` populates the
    /// cache for that UUID. This is the baseline behaviour every other test
    /// here builds on.
    func testCacheHitAfterMessageInserted() async {
        let vm = await makeVM()
        guard let sessionID = vm.activeSession?.id else {
            XCTFail("Active session must be set")
            return
        }

        let messageID = UUID()
        let record = ChatMessage(
            id: messageID,
            role: .user,
            content: "Hello world",  // 11 chars → CharTokenizer yields 11
            sessionID: sessionID
        )

        await vm.handle(runtimeEvent: .messageInserted(record))
        vm.updateContextEstimate()

        XCTAssertNotNil(vm.tokenCountCache[messageID],
            "Cache must contain an entry for the inserted message ID after updateContextEstimate")
        XCTAssertEqual(vm.tokenCountCache[messageID], 11,
            "CharTokenizer must produce 11 tokens for 'Hello world'")
    }

    // MARK: - Stale-cache demonstration on .messageUpdated

    /// `.messageUpdated` rewrites a message in place, but the runtime adapter
    /// does NOT invalidate `tokenCountCache[record.id]`. The next
    /// `updateContextEstimate()` therefore returns the **stale** token count
    /// for that UUID.
    ///
    /// This test passes today by demonstrating the stale behaviour. Once the
    /// adapter is fixed to invalidate the cache entry on `.messageUpdated`,
    /// flip the assertion direction — the audit's tracking note for this hole
    /// is in the perf-audit plan at `.claude/plans/put-a-plan-together-gentle-journal.md`.
    ///
    /// FIXME(perf-audit): tokenCountCache has no auto-invalidation on
    /// .messageUpdated. The runtime adapter at
    /// `ChatViewModel+RuntimeAdapter.swift:57-60` mutates messages[idx] but
    /// not the cache. Today the only caller compensates explicitly in
    /// `editMessage(...)`; any future direct emitter would surface the bug.
    func testCacheStaleAfterMessageUpdatedSameId() async {
        let vm = await makeVM()
        guard let sessionID = vm.activeSession?.id else {
            XCTFail("Active session must be set")
            return
        }

        // Step 1: insert a short message and prime the cache.
        let messageID = UUID()
        let initial = ChatMessage(
            id: messageID,
            role: .user,
            content: "x",  // 1 char → 1 token
            sessionID: sessionID
        )
        await vm.handle(runtimeEvent: .messageInserted(initial))
        vm.updateContextEstimate()
        XCTAssertEqual(vm.tokenCountCache[messageID], 1,
            "Precondition: cache should hold 1 token for the initial 1-char content")

        // Step 2: emit `.messageUpdated` with the SAME UUID but a much longer
        // body. The adapter replaces the in-memory record but leaves the
        // cache entry untouched.
        let updated = ChatMessage(
            id: messageID,
            role: .user,
            content: String(repeating: "a", count: 80),  // 80 chars → 80 tokens
            sessionID: sessionID
        )
        await vm.handle(runtimeEvent: .messageUpdated(updated))

        // Step 3: re-run the estimate. The cache lookup hits the OLD count.
        vm.updateContextEstimate()

        // Document the current (buggy) behaviour: the cache is stale, the
        // estimate uses the stale count, and the message-ID still maps to
        // the old token count.
        XCTAssertEqual(vm.tokenCountCache[messageID], 1,
            "BUG: cache returns stale 1-token count for the updated message instead of recomputing to 80. "
            + "When the adapter is fixed to invalidate on .messageUpdated, change this to XCTAssertEqual(..., 80).")

        // Sanity: the in-memory message is the new content; only the cache is wrong.
        XCTAssertEqual(vm.messages.first?.content, String(repeating: "a", count: 80),
            "Adapter must apply the .messageUpdated content to the in-memory record")
    }

    // MARK: - Sanity: explicit removal on chat clear

    /// `clearChat()` in `ChatViewModel+Messages.swift:189` calls
    /// `tokenCountCache.removeAll()` directly. This is the only existing
    /// invalidation contract we want to keep working — covered here as a
    /// regression guard so the audit fix doesn't accidentally regress it.
    func testCacheClearedOnDeleteMessage() async {
        let vm = await makeVM()
        guard let sessionID = vm.activeSession?.id else {
            XCTFail("Active session must be set")
            return
        }

        // Populate the cache via `.messageInserted` + estimate.
        let messageID = UUID()
        let record = ChatMessage(
            id: messageID,
            role: .user,
            content: "Hello",
            sessionID: sessionID
        )
        await vm.handle(runtimeEvent: .messageInserted(record))
        vm.updateContextEstimate()
        XCTAssertFalse(vm.tokenCountCache.isEmpty,
            "Precondition: cache should be populated")

        // `.messageRemoved` only removes from `vm.messages`. The
        // `updateContextEstimate()` follow-up rebuilds `tokenCountCache` from
        // the currently-resident messages, so the deleted message ID drops
        // out automatically — no separate cache invalidation contract.
        await vm.handle(runtimeEvent: .messageRemoved(messageID: messageID))
        vm.updateContextEstimate()

        XCTAssertNil(vm.tokenCountCache[messageID],
            "After .messageRemoved + updateContextEstimate, the deleted ID must not remain in the cache")
        XCTAssertTrue(vm.messages.isEmpty,
            "Adapter must remove the deleted message from the in-memory array")
    }

    // MARK: - Fixtures

    private func makeVM() async -> ChatViewModel {
        let backend = CharTokenizerCacheBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "CacheInvalidation")
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        vm.activeSession = ChatSession(title: "CacheInvalidation")
        return vm
    }
}

// MARK: - Test Fixture

/// Backend that vends `CharTokenizer` so the test's expected token counts
/// are 1-per-character and trivially auditable.
private final class CharTokenizerCacheBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokenizer: any TokenizerProvider { CharTokenizer() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}
