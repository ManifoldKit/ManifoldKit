@preconcurrency import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport

/// Integration tests verifying post-generation queue behavior.
///
/// These tests exercise the InferenceService queue from a consumer's
/// perspective: enqueue requests, let them auto-drain on stream terminate,
/// and verify ordering and lifecycle contracts.
@MainActor
final class PostGenerationQueueTests: XCTestCase {

    // MARK: - Controllable Mock

    /// A mock backend that blocks generation until explicitly released,
    /// enabling deterministic queue ordering verification.
    private final class GatedMockBackend: InferenceBackend, @unchecked Sendable {
        var isModelLoaded: Bool = true
        var isGenerating: Bool = false
        let capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        var gates: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []
        var generateCallCount = 0

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
            isModelLoaded = true
        }

        func generate(
            prompt: String,
            systemPrompt: String?,
            config: GenerationConfig,
            hints: GenerationRuntimeHints
        ) throws -> GenerationStream {
            generateCallCount += 1
            isGenerating = true
            let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
                self?.gates.append(continuation)
            }
            return GenerationStream(stream)
        }

        func stopGeneration() {
            isGenerating = false
            for gate in gates { gate.finish() }
        }

        func unloadModel() {
            isModelLoaded = false
            isGenerating = false
            for gate in gates { gate.finish() }
            gates.removeAll()
        }

        func release(at index: Int, tokens: [String] = ["tok"]) {
            guard index < gates.count else { return }
            for t in tokens {
                gates[index].yield(.token(t))
            }
            gates[index].finish()
            isGenerating = false
        }
    }

    // MARK: - Helpers

    private func makeService(
        backend: GatedMockBackend? = nil
    ) -> (InferenceService, GatedMockBackend) {
        let mock = backend ?? GatedMockBackend()
        let service = InferenceService(backend: mock, name: "GatedMock")
        return (service, mock)
    }

    // MARK: - 1. Post-generation background request executes

    func test_postGenerationTask_canEnqueueBackgroundRequest() async throws {
        let (service, mock) = makeService()

        // Primary user-initiated request.
        let (_, primaryStream) = try service.enqueue(messages: [Message.user("primary")], config: GenerationConfig(), priority: .userInitiated)

        XCTAssertEqual(primaryStream.phase, .connecting)
        XCTAssertTrue(service.isGenerating)

        // Let the drain Task run, then release the primary generation.
        await Task.yield()
        mock.release(at: 0, tokens: ["primary-tok"])

        // Consume the primary stream fully — queue auto-drains on stream terminate.
        for try await _ in primaryStream.events {}

        XCTAssertFalse(service.isGenerating,
                       "Service should be idle after stream terminates")

        // Now enqueue a background request, simulating a post-generation task.
        let (_, bgStream) = try service.enqueue(messages: [Message.user("background extraction")], config: GenerationConfig(), priority: .background)

        // With an empty queue and no active request, it should start immediately.
        XCTAssertEqual(bgStream.phase, .connecting,
                       "Background request should start immediately when queue is empty")
        XCTAssertTrue(service.isGenerating)

        // Let the drain Task run.
        await Task.yield()
        XCTAssertEqual(mock.generateCallCount, 2,
                       "Backend should have been called twice total")

        // Release the background generation.
        mock.release(at: 1, tokens: ["extracted", "-data"])

        var collected: [String] = []
        for try await event in bgStream.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }

        XCTAssertEqual(collected, ["extracted", "-data"])
        XCTAssertEqual(bgStream.phase, .done)
    }

    // MARK: - 2. Background request under nominal thermal state

    func test_backgroundRequest_executesUnderNominalThermalState() async throws {
        // Thermal gating drops .background requests under .serious/.critical
        // thermal pressure. ProcessInfo.processInfo.thermalState is read-only,
        // so we cannot simulate elevated thermal states in tests. Instead, we
        // verify that background requests execute normally under the .nominal
        // state that CI always has.
        //
        // Thermal gating under elevated pressure is verified through code review
        // of drainQueue() — the guard checks ProcessInfo.processInfo.thermalState
        // before dispatching .background requests.

        let (service, mock) = makeService()

        let (_, stream) = try service.enqueue(messages: [Message.user("background work")], config: GenerationConfig(), priority: .background)

        // Under .nominal thermal state, the request should start immediately.
        XCTAssertEqual(stream.phase, .connecting,
                       "Background request should proceed under nominal thermal state")

        await Task.yield()
        mock.release(at: 0, tokens: ["result"])

        var collected: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }

        XCTAssertEqual(collected, ["result"])
        XCTAssertEqual(stream.phase, .done)
    }

    // MARK: - 3. User-initiated request jumps ahead of queued background requests

    func test_userInitiatedRequest_proceedsRegardlessOfQueueDepth() async throws {
        let (service, mock) = makeService()

        // Start one request to occupy the active slot.
        let (_, activeStream) = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)
        XCTAssertEqual(activeStream.phase, .connecting)

        // Enqueue several background requests behind it.
        let (_, bg1Stream) = try service.enqueue(messages: [Message.user("bg1")], config: GenerationConfig(), priority: .background)
        let (_, bg2Stream) = try service.enqueue(messages: [Message.user("bg2")], config: GenerationConfig(), priority: .background)
        let (_, bg3Stream) = try service.enqueue(messages: [Message.user("bg3")], config: GenerationConfig(), priority: .background)

        // All background requests should be queued.
        XCTAssertEqual(bg1Stream.phase, .queued)
        XCTAssertEqual(bg2Stream.phase, .queued)
        XCTAssertEqual(bg3Stream.phase, .queued)

        // Now enqueue a user-initiated request — it should jump ahead.
        let (_, urgentStream) = try service.enqueue(messages: [Message.user("urgent")], config: GenerationConfig(), priority: .userInitiated)

        XCTAssertEqual(urgentStream.phase, .queued,
                       "Urgent request is queued because active slot is occupied")

        // Finish the active request.
        await Task.yield()
        mock.release(at: 0, tokens: ["done"])
        for try await _ in activeStream.events {}

        // The urgent request should be next, not bg1.
        XCTAssertEqual(urgentStream.phase, .connecting,
                       "User-initiated request should run before background requests")
        XCTAssertEqual(bg1Stream.phase, .queued,
                       "Background requests should still be queued")

        // Drain through all remaining requests to verify full ordering.
        // Expected order: urgent, bg1, bg2, bg3
        var executionOrder: [String] = []

        // Drain urgent.
        await Task.yield()
        mock.release(at: 1, tokens: ["urgent-tok"])
        for try await event in urgentStream.events {
            if case .token(let text) = event { executionOrder.append(text) }
        }


        // Drain bg1.
        XCTAssertEqual(bg1Stream.phase, .connecting)
        await Task.yield()
        mock.release(at: 2, tokens: ["bg1-tok"])
        for try await event in bg1Stream.events {
            if case .token(let text) = event { executionOrder.append(text) }
        }


        // Drain bg2.
        XCTAssertEqual(bg2Stream.phase, .connecting)
        await Task.yield()
        mock.release(at: 3, tokens: ["bg2-tok"])
        for try await event in bg2Stream.events {
            if case .token(let text) = event { executionOrder.append(text) }
        }


        // Drain bg3.
        XCTAssertEqual(bg3Stream.phase, .connecting)
        await Task.yield()
        mock.release(at: 4, tokens: ["bg3-tok"])
        for try await event in bg3Stream.events {
            if case .token(let text) = event { executionOrder.append(text) }
        }


        XCTAssertEqual(executionOrder, ["urgent-tok", "bg1-tok", "bg2-tok", "bg3-tok"],
                       "Execution order should be: urgent first, then background in FIFO")
        XCTAssertFalse(service.isGenerating)
        XCTAssertFalse(service.hasQueuedRequests)
    }
}
