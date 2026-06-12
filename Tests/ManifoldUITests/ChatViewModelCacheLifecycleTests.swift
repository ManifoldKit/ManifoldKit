@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Tests that `ChatViewModel`'s per-message token count cache is invalidated at
/// the correct moments so stale counts from a previous tokenizer (or previous
/// edit content) cannot leak back into ``ChatViewModel/updateContextEstimate()``.
@MainActor
final class ChatViewModelCacheLifecycleTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        mock: MockInferenceBackend = MockInferenceBackend()
    ) async -> (ChatViewModel, MockInferenceBackend, MemoryPressureHandler) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "CacheLifecycleMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        let session = ChatSession(title: "Cache Lifecycle")
        context.insert(session)
        try? context.save()
        await vm.switchToSession(session.toRecord())
        return (vm, mock, handler)
    }

    // MARK: - Bug 1: unloadModel clears the token cache

    /// A populated `tokenCountCache` must be cleared by `unloadModel()` so that
    /// counts computed with the old tokenizer are not returned after a later
    /// model swap picks up the same message UUIDs.
    func test_unloadModel_clearsTokenCountCache() async {
        let (vm, _, _) = await makeViewModel()

        // Populate the cache by sending a message.
        vm.inputText = "Cache population"
        await vm.sendMessage()

        XCTAssertFalse(vm.tokenCountCache.isEmpty,
            "Precondition: cache should be populated after sending a message")

        // Act: unload.
        vm.unloadModel()

        // Assert: cache is empty.
        XCTAssertTrue(vm.tokenCountCache.isEmpty,
            "tokenCountCache must be cleared by unloadModel() to prevent stale counts after a model swap")
    }

    /// Memory-pressure-driven unload (the primary motivating scenario) must
    /// also clear the cache, not just manual unloads.
    func test_memoryPressureCritical_clearsTokenCountCache() async {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = await makeViewModel(handler: handler)

        vm.inputText = "Memory pressure cache test"
        await vm.sendMessage()

        XCTAssertFalse(vm.tokenCountCache.isEmpty,
            "Precondition: cache should be populated after sending a message")

        // Simulate an OS critical memory pressure event.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        XCTAssertTrue(vm.tokenCountCache.isEmpty,
            "tokenCountCache must be cleared when memory pressure triggers an unload")
    }

    // MARK: - Bug 2: edited message cache entry is invalidated

    /// `editMessage()` keeps the same UUID but changes the content; any cached
    /// token count for that UUID must be dropped so the next
    /// `updateContextEstimate()` recomputes for the new content.
    func test_editMessage_invalidatesTokenCacheEntry() async {
        let (vm, mock, _) = await makeViewModel()

        // Send a user message and wait for the assistant reply.
        mock.tokensToYield = ["Hi"]
        vm.inputText = "x"                 // 1 char → heuristic yields 1 token
        await vm.sendMessage()

        let userID = vm.messages[0].id
        XCTAssertEqual(vm.tokenCountCache[userID], 1,
            "Precondition: short user message should cache as 1 token")
        let tokensBeforeEdit = vm.contextUsedTokens

        // Edit the user message to much longer content. The edit blocks on
        // regeneration (new assistant stream), so await it in full.
        mock.tokensToYield = ["Edited reply"]
        let longerContent = String(repeating: "a", count: 80) // 80 chars → 20 tokens
        await vm.editMessage(userID, newContent: longerContent)

        // The cache entry for the edited UUID must reflect the new content,
        // not the stale 1-token count from the original "x" text.
        let cachedAfterEdit = vm.tokenCountCache[userID]
        XCTAssertEqual(cachedAfterEdit, 20,
            "Edited message's cache entry must reflect the new content (80 chars → 20 tokens), not the stale count")
        XCTAssertGreaterThan(vm.contextUsedTokens, tokensBeforeEdit,
            "Context estimate must grow to reflect the longer edited content")
    }

    // MARK: - Bug 3: struct tokenizer identity discrimination

    /// Whitebox probe: when the backend keeps vending the **same** struct
    /// tokenizer type, the identity discriminator in
    /// ``ChatViewModel/reusableCachingTokenizer`` must produce the **same**
    /// `_cachingTokenizerBaseID` across successive rebuilds.
    ///
    /// With the corrected `type(of:) is AnyClass` discriminator, the value-type
    /// branch keys on the metatype, which is a stable `ObjectIdentifier` for a
    /// given Swift type. With the earlier `as? AnyObject` code, Swift's
    /// `_SwiftValue` boxing allocates a fresh heap box on each call, so the
    /// recorded `ObjectIdentifier`s would (almost always) diverge.
    func test_reusableCachingTokenizer_sameStructType_producesStableBaseID() async {
        let backend = StructTokenizerVendorBackend()
        let service = InferenceService(backend: backend, name: "StructVendor")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        // Precondition: fixture must vend a value-type tokenizer so we hit the
        // struct branch of the discriminator.
        if let resolved = service.tokenizer {
            XCTAssertFalse(type(of: resolved) is AnyClass,
                "Fixture must vend a value-type tokenizer to exercise the struct branch")
        } else {
            XCTFail("Fixture must vend a tokenizer")
        }

        _ = vm.reusableCachingTokenizer
        let firstBaseID = vm._testOnly_cachingTokenizerBaseID
        XCTAssertNotNil(firstBaseID, "Base ID must be recorded when a backend tokenizer is vended")

        // Invalidate the VM-level cache so the next access recomputes the
        // identity from scratch — the discriminator re-runs against the same
        // struct type and must produce the same ObjectIdentifier.
        vm.invalidateTokenCaches()

        _ = vm.reusableCachingTokenizer
        let secondBaseID = vm._testOnly_cachingTokenizerBaseID

        XCTAssertEqual(firstBaseID, secondBaseID,
            "Same struct tokenizer type must yield the same _cachingTokenizerBaseID — "
            + "the metatype is stable; _SwiftValue boxing under `as? AnyObject` would produce a fresh ID each time")
    }

    /// Whitebox probe: when the backend swaps to a **different** struct
    /// tokenizer type, the identity discriminator must produce a **different**
    /// `_cachingTokenizerBaseID`.
    ///
    /// Under the corrected `type(of:) is AnyClass` discriminator, different
    /// Swift struct types have distinct metatype `ObjectIdentifier`s, so this
    /// is guaranteed. Under the earlier `as? AnyObject` code, the type change
    /// is irrelevant — every call boxes afresh and the IDs already differ for
    /// reasons unrelated to the actual semantic change, so this assertion is
    /// about the *positive* case of the fix: different types really do get
    /// different IDs, not the accidental result of boxing nondeterminism.
    func test_reusableCachingTokenizer_differentStructTypes_produceDifferentBaseIDs() async {
        let backend = SwitchableStructTokenizerVendorBackend()
        let service = InferenceService(backend: backend, name: "SwitchableVendor")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        // Precondition: confirm the two variants are distinct value types.
        let firstTokenizer = backend.tokenizer
        backend.useSecondVariant = true
        let secondTokenizer = backend.tokenizer
        backend.useSecondVariant = false
        XCTAssertFalse(type(of: firstTokenizer) is AnyClass,
            "Variant A must be a value type")
        XCTAssertFalse(type(of: secondTokenizer) is AnyClass,
            "Variant B must be a value type")
        XCTAssertNotEqual(
            ObjectIdentifier(type(of: firstTokenizer)),
            ObjectIdentifier(type(of: secondTokenizer)),
            "Fixtures must vend genuinely different Swift types to exercise the discriminator"
        )

        _ = vm.reusableCachingTokenizer
        let firstBaseID = vm._testOnly_cachingTokenizerBaseID
        XCTAssertNotNil(firstBaseID, "Base ID must be recorded for variant A")

        // Swap the backend's vended tokenizer type and clear the VM's cached
        // identity so the next access recomputes.
        backend.useSecondVariant = true
        vm.invalidateTokenCaches()

        _ = vm.reusableCachingTokenizer
        let secondBaseID = vm._testOnly_cachingTokenizerBaseID

        XCTAssertNotEqual(firstBaseID, secondBaseID,
            "Different struct tokenizer types must yield different _cachingTokenizerBaseIDs — "
            + "the discriminator must key on the metatype so downstream consumers can detect the swap")
    }
}

// MARK: - Test Fixtures

/// Backend that vends a struct-based tokenizer. Exercises the value-type branch
/// of the identity discriminator in ``ChatViewModel/reusableCachingTokenizer``.
private struct StubStructTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}

/// A second, deliberately distinct struct tokenizer type (not just a variant of
/// the first with different fields — a genuinely different Swift metatype) so
/// the two produce different `ObjectIdentifier(type(of:))` values.
private struct AlternateStubStructTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { max(1, text.count / 2) }
}

private final class StructTokenizerVendorBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokenizer: any TokenizerProvider { StubStructTokenizer() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}

/// Backend that can flip between two genuinely different struct tokenizer
/// types at runtime, without requiring a full `InferenceService` reconfigure.
/// Used to verify the discriminator keys on the Swift metatype, not on the
/// particular existential box.
private final class SwitchableStructTokenizerVendorBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    /// Flips which struct type is vended. The backing types are distinct Swift
    /// structs, so they have different metatypes and different
    /// `ObjectIdentifier(type(of:))` values.
    var useSecondVariant: Bool = false

    var tokenizer: any TokenizerProvider {
        useSecondVariant ? AlternateStubStructTokenizer() : StubStructTokenizer()
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}
