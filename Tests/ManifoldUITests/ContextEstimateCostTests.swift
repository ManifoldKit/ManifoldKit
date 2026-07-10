@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport
@testable import ManifoldInference
@testable import ManifoldTestSupport

/// Perf-audit β-1: ChatViewModel hot-path measurements for `updateContextEstimate`.
///
/// These XCTMeasure baselines quantify the cost the audit attributed to the
/// per-token `updateContextEstimate()` call that runs after every streamed
/// turn (`ChatViewModel+RuntimeAdapter.swift:104`). The measurement isolates
/// the estimator + cache work — not tokenizer-specific cost — by vending
/// `ManifoldTestSupport.CharTokenizer` (1 token per character, deterministic).
///
/// ## Why CharTokenizer
///
/// The audit's claim is about the **estimator + cache loop**, not the tokenizer
/// itself. Real backends vend tokenizers whose cost per call varies wildly:
/// `LlamaBackend` shells out to a C tokenizer; `FoundationBackend` uses
/// `SystemLanguageModel`'s tokenizer; the heuristic fallback divides string
/// length by 4. Pinning a deterministic 1-char-per-token tokenizer makes the
/// measurement isolate the per-message cache lookup + Dictionary write cost,
/// which is what every `updateContextEstimate()` call pays regardless of
/// backend. Backend-specific tokenizer cost gets its own measurement (see
/// `TokenizationPerformanceTests`).
///
/// ## Cold vs primed cache
///
/// `updateContextEstimate()` reads `tokenCountCache` keyed by message UUID and
/// emits an updated cache that becomes the next call's input. Two paths:
///
///  - **Cold cache**: every message misses the cache, so `tokenCount(...)`
///    runs once per message. This is the worst case — first call after a
///    cache invalidation (model swap, memory pressure, edit, clearChat).
///  - **Primed cache**: every message hits the cache, so the loop is pure
///    Dictionary lookups. This is the steady-state cost paid every time
///    `updateContextEstimate()` runs after a streamed turn finishes.
///
/// The delta between cold and primed quantifies the cache's effectiveness.
///
/// ## CI gating
///
/// Nightly only. The 200-message variants seed a few hundred VM messages and
/// run `XCTMeasure`'s default 10 iterations, which would inflate per-PR CI.
/// Gated by `RUN_SLOW_TESTS=1` (see `.github/workflows/nightly-slow-tests.yml`).
/// Local `swift test` runs them unconditionally because `CI` is unset.
@MainActor
final class ContextEstimateCostTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
                      "Nightly perf test — gated by RUN_SLOW_TESTS=1")
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - Cold cache

    func testContextEstimateCostColdCache_10Messages() async throws {
        let vm = await makeVM()
        seedMessages(in: vm, count: 10)

        // Iteration body re-runs `updateContextEstimate` from a CLEARED cache,
        // so each tick measures the worst case (every message misses).
        measure {
            vm.tokenCountCache = [:]
            vm.updateContextEstimate()
        }
    }

    func testContextEstimateCostColdCache_50Messages() async throws {
        let vm = await makeVM()
        seedMessages(in: vm, count: 50)

        measure {
            vm.tokenCountCache = [:]
            vm.updateContextEstimate()
        }
    }

    func testContextEstimateCostColdCache_200Messages() async throws {
        let vm = await makeVM()
        seedMessages(in: vm, count: 200)

        measure {
            vm.tokenCountCache = [:]
            vm.updateContextEstimate()
        }
    }

    // MARK: - Primed cache

    /// Steady-state cost paid every time a streaming turn finishes and the
    /// runtime adapter calls `updateContextEstimate()`. The cache is left
    /// populated between iterations, so each iteration is a pure
    /// Dictionary-lookup loop.
    func testContextEstimateCostPrimedCache_200Messages() async throws {
        let vm = await makeVM()
        seedMessages(in: vm, count: 200)
        // Prime the cache once — subsequent calls inside `measure { }` hit
        // every cached entry.
        vm.updateContextEstimate()

        measure {
            vm.updateContextEstimate()
        }
    }

    // MARK: - Fixtures

    /// Builds a `ChatViewModel` whose backend vends a deterministic
    /// `CharTokenizer` (1 token per character). The estimator goes through
    /// `inferenceService.tokenizer`, so the backend must adopt
    /// `TokenizerVendor` to override the heuristic fallback.
    private func makeVM() async -> ChatViewModel {
        let backend = CharTokenizerVendorBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "PerfAuditCharTokenizer")
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        let session = ManifoldInference.ChatSession(title: "ContextEstimateCost")
        vm.activeSession = session
        return vm
    }

    /// Seeds `count` alternating user/assistant messages directly on the VM's
    /// in-memory `messages` array. Each message body is ~80 chars to match the
    /// fixture in `IntegratedStreamingPerformanceTests` (and to give the
    /// CharTokenizer non-trivial counts).
    private func seedMessages(in vm: ChatViewModel, count: Int) {
        guard let sessionID = vm.activeSession?.id else {
            XCTFail("Active session must be set before seeding messages")
            return
        }
        let base = Date(timeIntervalSince1970: 1_000_000)
        var seeded: [ManifoldInference.ChatMessage] = []
        seeded.reserveCapacity(count)
        for i in 0..<count {
            let role: MessageRole = i.isMultiple(of: 2) ? .user : .assistant
            let body = "Backlog message \(i): the quick brown fox jumps over the lazy dog every time."
            let record = ManifoldInference.ChatMessage(
                role: role,
                content: body,
                timestamp: base.addingTimeInterval(Double(i)),
                sessionID: sessionID
            )
            seeded.append(record)
        }
        vm.messages = seeded
    }
}

// MARK: - Test Fixture: backend vending a CharTokenizer

/// A minimal `InferenceBackend` that vends `CharTokenizer` so the estimator's
/// per-message cost reflects only the cache + dictionary work, not
/// tokenizer-specific cost. Generation is a no-op stream — these tests never
/// run a turn, they only call `updateContextEstimate()` directly.
private final class CharTokenizerVendorBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
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
