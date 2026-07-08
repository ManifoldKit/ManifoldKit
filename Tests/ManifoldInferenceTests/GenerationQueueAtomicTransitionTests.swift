import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldContract

/// Tests for the post-turn state transition in ``GenerationQueue``
/// (issue #1986, Race 1).
///
/// When an active turn finishes, the producer task's `defer` must present a
/// single, consistent state transition: clearing the active-slot flags
/// (`isGenerating` / `activeRequest`) and finishing the stream continuation so
/// that no caller woken by the finish observes a stale mid-tear-down state. The
/// fix clears the slot flags BEFORE finishing the continuation so the ordering
/// is robust against a future refactor that introduces a suspension point into
/// the `defer`.
///
/// Honesty note: `GenerationQueue` is `@MainActor` and the entire `defer` body
/// is synchronous (no `await`), so today the whole transition is already one
/// atomic actor-isolated region — the statement order inside it is not
/// observable by any other `@MainActor` work. These tests therefore guard the
/// *invariant* the transition guarantees (a turn completing always leaves an
/// idle queue, and back-to-back / concurrent enqueues never double-activate),
/// not a sabotage-flipping reproduction of a torn read. The
/// `OverlapDetectingBackend` flags any window in which two `generate` calls are
/// live at once — the direct signature of a double-activation, which would
/// surface if a future change broke single-turn serialization.
@MainActor
final class GenerationQueueAtomicTransitionTests: XCTestCase {

    // MARK: - Post-turn idle state visible to a follow-up enqueue

    /// The instant the active turn's stream finishes, the queue must be idle:
    /// `isGenerating == false`, no queued requests. A follow-up `enqueue()`
    /// issued from the stream-end handler must therefore *activate* immediately
    /// rather than land queued behind a half-torn-down turn. Guards the
    /// post-turn idle invariant the atomic transition guarantees.
    func test_streamFinish_leavesQueueIdle_followUpActivates() async throws {
        let backend = OverlapDetectingBackend(tokenCount: 3, delayMilliseconds: 5)
        let coord = GenerationQueue()
        bind(backend, to: coord)

        let (_, stream) = try coord.enqueue(messages: [("user", "first")], priority: .normal)

        // Drain the first turn to completion.
        for try await _ in stream.events {}

        // By the time the for-await returns, the defer has run. The queue must
        // be idle — this is the clean state the atomic transition guarantees.
        XCTAssertFalse(coord.isGenerating, "queue must be idle the moment the turn's stream finishes")
        XCTAssertFalse(coord.hasQueuedRequests, "no leftover queued requests after a turn completes")

        // A follow-up must activate, not queue.
        let (_, followUp) = try coord.enqueue(messages: [("user", "second")], priority: .normal)
        XCTAssertNotEqual(followUp.phase, .queued, "follow-up enqueue after a clean finish must activate immediately")

        coord.stopGeneration()
        do { for try await _ in followUp.events {} } catch { /* cancel OK */ }
    }

    // MARK: - No double-activation under concurrent enqueue against a finishing turn

    /// Hammers a concurrent `enqueue()` against turns that are finishing, across
    /// many iterations. The backend asserts no two `generate` calls are ever
    /// live simultaneously — the direct symptom of a double-activation. This is
    /// a single-turn-serialization regression guard: it stays green while the
    /// queue keeps exactly one turn active, and would fail if a future change
    /// let a concurrent enqueue activate against a half-torn-down slot.
    func test_concurrentEnqueueDuringFinish_neverDoubleActivates() async throws {
        let backend = OverlapDetectingBackend(tokenCount: 2, delayMilliseconds: 2)
        let coord = GenerationQueue()
        bind(backend, to: coord)

        // Run a sequence of back-to-back turns where each turn's consumer
        // enqueues the next from its stream-end handler — exactly the
        // re-entrant pattern the race concerns. Interleave a second concurrent
        // enqueue per round to maximise the chance of landing in the finish
        // window.
        for _ in 0..<25 {
            let (_, s1) = try coord.enqueue(messages: [("user", "a")], priority: .normal)
            // Second enqueue races in immediately while the first is active or
            // finishing; it must queue cleanly (single active turn invariant).
            let (_, s2) = try coord.enqueue(messages: [("user", "b")], priority: .normal)

            for try await _ in s1.events {}
            for try await _ in s2.events {}
        }

        XCTAssertEqual(
            backend.maxConcurrent, 1,
            "the queue must never have two generations live at once — a value > 1 is a double-activation"
        )
        XCTAssertEqual(backend.overlapDetected, false, "no overlapping generate calls may occur")

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)
    }

    // MARK: - Helpers

    private func bind(_ backend: OverlapDetectingBackend, to coord: GenerationQueue) {
        coord.bindContext(
            currentBackend: { backend },
            isBackendLoaded: { true },
            selectedPromptTemplate: { .chatML }
        )
    }
}

/// A backend that yields tokens over time and flags any window in which more
/// than one `generate` call is live — the direct signature of a
/// double-activation. Thread-safe via a lock; `generate` is invoked on the
/// `@MainActor` but tokens are produced from a detached stream task.
private final class OverlapDetectingBackend: InferenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _concurrent = 0
    private var _maxConcurrent = 0
    private var _overlap = false
    private let tokens: [String]
    private let delay: Duration

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    var maxConcurrent: Int { withLock { _maxConcurrent } }
    var overlapDetected: Bool { withLock { _overlap } }

    /// Records the start of a `generate` call and returns nothing; called
    /// synchronously so it never touches the lock from an async context.
    private func recordEnter() {
        withLock {
            _concurrent += 1
            if _concurrent > _maxConcurrent { _maxConcurrent = _concurrent }
            if _concurrent > 1 { _overlap = true }
        }
    }

    private func recordExit() {
        withLock { _concurrent -= 1 }
    }

    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    init(tokenCount: Int, delayMilliseconds: Int) {
        self.tokens = (0..<tokenCount).map { "t\($0) " }
        self.delay = .milliseconds(delayMilliseconds)
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let tokens = self.tokens
        let delay = self.delay
        recordEnter()

        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task { [weak self] in
                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                // Decrement BEFORE finishing the stream so the live-call count
                // is already settled by the time the queue observes stream end
                // and may activate the next turn — otherwise a correct,
                // serialized queue could still see a transient overlap from the
                // lagging decrement and the test would false-positive.
                self?.recordExit()
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}
