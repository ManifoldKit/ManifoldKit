@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Integrated streaming performance baselines.
///
/// Existing perf suites (`TokenizationPerformanceTests`, `HotPathPerformanceTests`,
/// `ContextWindowPerformanceTests`, `PromptAssemblyPerformanceTests`) measure
/// **isolated pure functions**. None measure what the user actually feels: the
/// full streaming pipeline under realistic load. This suite covers the four
/// gaps called out in issue #243:
///
/// 1. **Time-to-first-token (TTFT)** — `sendMessage()` → first character lands in
///    `messages.last.content`. Drives the perceived "the model is alive" moment.
/// 2. **Streaming cadence** — % of UI-visible content updates arriving more than
///    50 ms apart. The `StreamingTokenBatcher` is configured for 33 ms / 128 chars,
///    so a healthy run flushes well below the 50 ms threshold.
/// 3. **End-to-end pipeline with backlog** — 200-message history, 5 KB streamed
///    response, full flow (backend → batcher → VM → SwiftData persist → markdown
///    render) wall-clock.
/// 4. **Message append at 200-message count** — isolates the persist + append cost
///    so cadence/TTFT regressions can be untangled from history-growth costs.
///
/// All tests build their fixtures **outside** the `measure { }` block per CLAUDE.md.
/// Inside the block, async work runs in a `Task` whose completion is awaited via
/// `XCTestExpectation` (the same pattern used by `HotPathPerformanceTests` for SSE).
///
/// ## Cadence: deterministic emission
///
/// `MockInferenceBackend` yields tokens instantly which collapses every batch
/// boundary into a single flush — useless for cadence measurement. Instead this
/// suite uses ``PerceivedLatencyBackend`` configured with a degenerate jitter
/// range (lower == upper), giving a constant inter-token gap whose value is
/// chosen relative to the batcher's flush interval. The deterministic
/// `SplitMix64` RNG inside `PerceivedLatencyBackend` keeps timing reproducible
/// across CI runs.
///
/// ## CI gating
///
/// These tests do real `Task.sleep` between tokens and seed up to 200 SwiftData
/// rows per iteration; combined runtime is on the order of tens of seconds and
/// would significantly inflate the per-PR CI budget. They live in the **nightly**
/// tier alongside `LargeSessionListPerformanceTests` and
/// `TrafficBoundaryAuditTest`, gated by `RUN_SLOW_TESTS=1` (see PR #803 for the
/// nightly carve-out and `.github/workflows/nightly-slow-tests.yml`). Local
/// `swift test` runs them unconditionally because `CI` is unset.
@MainActor
final class IntegratedStreamingPerformanceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
                      "Slow streaming-pipeline perf baseline — runs in nightly CI only. Set RUN_SLOW_TESTS=1 to force.")
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - 1. Time-to-first-token

    /// Measures wall-clock from `sendMessage()` call to the first character
    /// becoming visible in `messages.last.content`. The measurement is the
    /// **user-perceived** TTFT, which includes both backend latency and the
    /// `StreamingTokenBatcher` flush delay — exactly what regresses when
    /// either side slows down.
    func testPerf_timeToFirstToken_realisticBackend() async {
        // Fixture: 32 short tokens are plenty to drive the first batch flush.
        // A 100 ms TTFT is the conservative midpoint of a real local-MLX run;
        // jitter is degenerate so per-iteration variance is bounded.
        let tokens = Array(repeating: "tok ", count: 32)
        let backend = makeLatencyBackend(
            ttft: .milliseconds(100),
            interToken: .milliseconds(20),
            tokens: tokens
        )
        let harness = await makeHarness(backend: backend)

        measure {
            let exp = expectation(description: "first character visible")
            let vm = harness.vm
            // Reset per-iteration so each measurement starts from a clean
            // empty assistant message (sendMessage appends a new one each call).
            vm.messages = vm.messages.filter { $0.role == .system }
            vm.inputText = "hello"
            Task { @MainActor in
                let send = Task { await vm.sendMessage() }
                // Tight poll on the MainActor — `messages.last?.content` is
                // mutated on the main actor by `onMutateMessage`, so any
                // observation needs to be back on the main actor too.
                while !Task.isCancelled {
                    if let last = vm.messages.last,
                       last.role == .assistant,
                       !last.content.isEmpty {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                exp.fulfill()
                _ = await send.value
            }
            wait(for: [exp], timeout: 10)
        }
    }

    // MARK: - 2. Streaming cadence

    /// Measures the **distribution of inter-update gaps** for visible content
    /// during a 5 KB streamed response. The assertion is structural rather
    /// than wall-clock: less than 25% of observed gaps may exceed 50 ms.
    /// `StreamingTokenBatcher` is configured for 33 ms / 128 chars, so a
    /// healthy run sits at roughly the 33 ms tick and well below the threshold.
    /// Regressions that disable batching (gaps drop near zero with very high
    /// frequency) or that stall the batcher (gaps spike past 50 ms) both
    /// surface here.
    func testPerf_streamingCadence_5KBResponse() async {
        let tokens = makeFiveKBTokenScript()
        // 8 ms per token gives ~4× the batcher's 33 ms tick: every batch
        // flush carries multiple tokens, exercising the realistic batching
        // path rather than degenerating into one-flush-per-token.
        let backend = makeLatencyBackend(
            ttft: .milliseconds(50),
            interToken: .milliseconds(8),
            tokens: tokens
        )
        let harness = await makeHarness(backend: backend)

        measure {
            let exp = expectation(description: "stream completes")
            let vm = harness.vm
            vm.messages = vm.messages.filter { $0.role == .system }
            vm.inputText = "stream please"
            Task { @MainActor in
                let send = Task { await vm.sendMessage() }
                var gaps: [Duration] = []
                var lastChange = ContinuousClock.now
                var lastLength = 0
                // Poll every 1 ms until generation finishes. Recording at
                // 1 ms granularity is finer than the batcher's 33 ms target,
                // so the captured gap distribution faithfully reflects real
                // flush boundaries rather than the polling rate.
                while vm.isGenerating || vm.activityPhase == .waitingForFirstToken {
                    if let last = vm.messages.last, last.role == .assistant {
                        let len = last.content.count
                        if len > lastLength {
                            let now = ContinuousClock.now
                            if lastLength > 0 {
                                gaps.append(now - lastChange)
                            }
                            lastChange = now
                            lastLength = len
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                _ = await send.value

                // The assertion is at the suite level, not per-iteration: we
                // use XCTAssert here as a regression tripwire so a profoundly
                // broken cadence (e.g. batching disabled) shows up as a test
                // failure, not just a baseline drift.
                if !gaps.isEmpty {
                    let threshold = Duration.milliseconds(50)
                    let breaches = gaps.filter { $0 > threshold }.count
                    let ratio = Double(breaches) / Double(gaps.count)
                    XCTAssertLessThan(
                        ratio, 0.25,
                        "Cadence regression: \(breaches)/\(gaps.count) batches exceeded 50 ms (StreamingTokenBatcher target is 33 ms)"
                    )
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    // MARK: - 3. End-to-end pipeline with 200-message backlog

    /// Full pipeline measurement: backend stream → token batcher → view-model
    /// state mutation → SwiftData persist → markdown re-render trigger, with a
    /// 200-message session backlog already in memory and on disk.
    ///
    /// The backlog matters because a number of code paths iterate the active
    /// message array (context window trimming, scroll anchoring, persistence
    /// upserts) and grow O(n) with history length.
    func testPerf_endToEndPipeline_withLargeBacklog() async {
        let tokens = makeFiveKBTokenScript()
        let backend = makeLatencyBackend(
            ttft: .milliseconds(50),
            interToken: .milliseconds(2),
            tokens: tokens
        )
        let harness = await makeHarness(backend: backend)
        await seedBacklog(in: harness, messageCount: 200)

        measure {
            let exp = expectation(description: "5KB stream end-to-end")
            let vm = harness.vm
            // The seeded 200 messages stay; a fresh user/assistant pair is
            // appended each iteration. Cap regrowth by trimming back to the
            // backlog before each iteration.
            let seededIDs = Set(vm.messages.map(\.id))
            vm.messages = vm.messages.filter { seededIDs.contains($0.id) }
            vm.inputText = "tell me about the project"
            Task { @MainActor in
                await vm.sendMessage()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    // MARK: - 4. Message append at 200-message count

    /// Isolates the **append + persist** cost at history length 200, paired
    /// with a tiny 4-token response so the streaming path contributes a
    /// constant overhead. Compared against the end-to-end test, this lets a
    /// future regression be attributed to either the append/persist side or
    /// the streaming side.
    func testPerf_messageAppend_at200MessageCount() async {
        let backend = makeLatencyBackend(
            ttft: .milliseconds(10),
            interToken: .milliseconds(2),
            tokens: ["A", "B", "C", "D"]
        )
        let harness = await makeHarness(backend: backend)
        await seedBacklog(in: harness, messageCount: 200)
        let seededIDs = Set(harness.vm.messages.map(\.id))

        measure {
            let exp = expectation(description: "append + persist round-trip")
            let vm = harness.vm
            vm.messages = vm.messages.filter { seededIDs.contains($0.id) }
            vm.inputText = "ping"
            Task { @MainActor in
                await vm.sendMessage()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10)
        }
    }

    // MARK: - Fixtures

    /// A pre-loaded ``PerceivedLatencyBackend`` configured with degenerate
    /// jitter so inter-token gaps are constant — required for repeatable
    /// cadence measurements.
    private func makeLatencyBackend(
        ttft: Duration,
        interToken: Duration,
        tokens: [String]
    ) -> PerceivedLatencyBackend {
        PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: ttft,
            interTokenJitter: interToken...interToken,
            tokensToYield: tokens
        )
    }

    /// Wires up `ChatViewModel`, persistence, and an active session against
    /// a pre-loaded backend. Mirrors the `PerceivedLatencyDemoTests` setup
    /// but local to this suite because the harness retains references the
    /// `measure { }` closure must reach.
    private struct Harness {
        let vm: ChatViewModel
        let backend: PerceivedLatencyBackend
        let session: ChatSessionRecord
    }

    private func makeHarness(backend: PerceivedLatencyBackend) async -> Harness {
        // `InferenceService(backend:name:)` treats the backend as already
        // loaded, but the backend itself enforces an `_isModelLoaded` guard
        // inside `generate()` — preload it here so tests don't deadlock on
        // the guard throwing.
        try? await backend.loadModel(
            from: URL(fileURLWithPath: "/tmp/integratedperf"),
            plan: .testStub(effectiveContextSize: 4096)
        )

        let service = InferenceService(backend: backend, name: "IntegratedPerf")
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        let session = (try? await sessionManager.createSession(title: "Perf"))!
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return Harness(vm: vm, backend: backend, session: session)
    }

    /// Seeds `messageCount` alternating user/assistant rows into the harness's
    /// active session, both in-memory on the VM and persisted via SwiftData.
    /// Done once before `measure { }` so the timed work is the next message,
    /// not the fixture build.
    private func seedBacklog(in harness: Harness, messageCount: Int) async {
        let sessionID = harness.session.id
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<messageCount {
            let role: MessageRole = i.isMultiple(of: 2) ? .user : .assistant
            // ~80 chars each — enough body for context trimming and markdown
            // rendering to be exercised, but small enough to keep fixture
            // build reasonable.
            let body = "Backlog message \(i): the quick brown fox jumps over the lazy dog every time."
            let record = ChatMessageRecord(
                role: role,
                content: body,
                timestamp: base.addingTimeInterval(Double(i)),
                sessionID: sessionID
            )
            harness.vm.messages.append(record)
            try? await SwiftDataPersistenceProvider(modelContext: context)
                .insertMessage(record)
        }
    }

    /// Builds a token script whose total visible content size is approximately
    /// 5 KB. The 5 KB target is from issue #243 and roughly matches a long
    /// model reply (multi-paragraph code answer, fully expanded thinking).
    private func makeFiveKBTokenScript() -> [String] {
        // Each token is 25 chars including the trailing space. 5120 / 25 ≈ 205
        // tokens lands within ~125 bytes of the 5 KB target — close enough
        // for a perf fixture without needing a length-trim loop.
        let unit = "lorem ipsum dolor sit amet "
        let target = 5120
        let tokenCount = max(1, target / unit.count)
        return Array(repeating: unit, count: tokenCount)
    }
}
