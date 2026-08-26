@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``ImageGenerationRuntime`` — the image-side sibling to
/// ``ConversationRuntime``. Drives a mock ``ImageGenerationBackend`` through
/// the runtime, asserts events and persistence.
@MainActor
final class ImageGenerationRuntimeTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        var updateError: (any Error)?

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }

        func updateMessage(_ message: ChatMessage) async throws {
            if let error = updateError {
                updateError = nil
                throw error
            }
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Mock image-gen backend
    //
    // Drives `ImageGenerationService.generate(...)` through a controllable
    // stream. Each test configures the events the backend yields and the
    // delay between them; the service wraps this stream and the runtime
    // consumes from there.

    final class MockImageBackend: ImageGenerationBackend, @unchecked Sendable {
        struct Plan: Sendable {
            var events: [ImageGenerationEvent] = []
            /// When non-nil the stream throws this error after yielding all
            /// configured events.
            var trailingError: (any Error)?
            /// Per-event delay in nanoseconds. Tests can use a small value
            /// to give cancellation a chance to interleave.
            var delayPerEventNs: UInt64 = 1_000_000  // 1ms
        }

        private struct State: Sendable {
            var isLoaded = true
            var isGenerating = false
            var plan = Plan()
            var stopRequested = false
            /// The exact `config` the most recent `generate(prompt:config:)`
            /// call received — captured so tests can assert on what actually
            /// reached the backend seam (through `ImageGenerationService`,
            /// not just what the runtime snapshotted before the call), rather
            /// than trusting that nothing between the caller and this mock
            /// silently substituted a different value.
            var receivedConfig: ImageGenerationConfig?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var isLoaded: Bool { state.withLock { $0.isLoaded } }
        var isGenerating: Bool { state.withLock { $0.isGenerating } }
        var stopRequested: Bool { state.withLock { $0.stopRequested } }
        var receivedConfig: ImageGenerationConfig? { state.withLock { $0.receivedConfig } }

        func setPlan(_ plan: Plan) {
            state.withLock { $0.plan = plan }
        }

        func loadModel(from url: URL) async throws {
            state.withLock { $0.isLoaded = true }
        }

        func generate(
            prompt: String,
            config: ImageGenerationConfig
        ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
            let plan: Plan = state.withLock { snapshot in
                snapshot.isGenerating = true
                snapshot.stopRequested = false
                snapshot.receivedConfig = config
                return snapshot.plan
            }

            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> { [self] in
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    if let trailingError = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailingError)
                    } else {
                        continuation.finish()
                    }
                    self.state.withLock { $0.isGenerating = false }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        func stopGeneration() {
            state.withLock { snapshot in
                snapshot.stopRequested = true
                snapshot.isGenerating = false
            }
        }

        func unloadModel() {
            state.withLock { $0.isLoaded = false }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        backend: MockImageBackend = MockImageBackend(),
        modelIdentifier: String? = "test-model"
    ) async throws -> (
        runtime: ImageGenerationRuntime,
        store: RuntimeMessageStore,
        backend: MockImageBackend,
        service: ImageGenerationService
    ) {
        let service = ImageGenerationService()
        // Register a factory that yields our mock so the service has a
        // backend to call. The factory is invoked synchronously during
        // `loadModel` — which we don't drive here; instead we hand the
        // service a pre-loaded backend by overriding the identifier
        // resolver and calling `loadModel` ourselves through the factory.
        let captured = backend
        service.registerBackendFactory(for: .mlxDiffusion) { _ in
            captured
        }
        let info = ImageModelInfo(
            id: modelIdentifier ?? "test-model",
            name: "Test Model",
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            format: .mlxDiffusion,
            fileSize: 1
        )
        try await service.loadModel(info)

        let store = RuntimeMessageStore()
        let runtime = ImageGenerationRuntime(
            service: service,
            messageStore: store
        )
        return (runtime, store, backend, service)
    }

    /// Drains events until `predicate` is true or `deadline` elapses.
    private func collectEvents(
        from runtime: ImageGenerationRuntime,
        until predicate: @escaping @Sendable (ImageRuntimeEvent) -> Bool,
        deadline: Duration = .seconds(5)
    ) async throws -> [ImageRuntimeEvent] {
        var collected: [ImageRuntimeEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        let result = try await withThrowingTaskGroup(of: [ImageRuntimeEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestError.deadlineElapsed
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
        return result
    }

    enum TestError: Error { case deadlineElapsed }

    // MARK: - Test 1: Generate happy path

    func test_generate_happyPath_persistsAndEmitsEvents() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let imageURL = outDir.appendingPathComponent("out.png")
        // Write a real placeholder file so the URL points at on-disk bytes —
        // the runtime doesn't read the file, but tests that assert on
        // payload validity should reflect realistic state.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 4),
            .progress(step: 2, total: 4),
            .progress(step: 3, total: 4),
            .progress(step: 4, total: 4),
            .completed(imageURL)
        ]))

        let (runtime, store, _, _) = try await makeRuntime(backend: backend)
        let sessionID = UUID()
        let config = ImageGenerationConfig(steps: 4, width: 64, height: 64, outputDirectory: outDir)

        let messageID = try await runtime.generate(
            prompt: "a cat",
            config: config,
            in: sessionID
        )

        let events = try await collectEvents(from: runtime) { event in
            if case .completed = event { return true }
            if case .failed = event { return true }
            return false
        }

        // Check event sequence: started → 4× progress → completed.
        XCTAssertEqual(events.count, 6)
        guard case .started(let startID, let prompt) = events.first else {
            return XCTFail("Expected first event to be .started, got \(events.first as Any)")
        }
        XCTAssertEqual(startID, messageID)
        XCTAssertEqual(prompt, "a cat")

        for (i, event) in events[1...4].enumerated() {
            guard case .progress(let pid, let step, let total) = event else {
                return XCTFail("Expected progress at index \(i+1), got \(event)")
            }
            XCTAssertEqual(pid, messageID)
            XCTAssertEqual(step, i + 1)
            XCTAssertEqual(total, 4)
        }

        guard case .completed(let cid, let payload) = events.last else {
            return XCTFail("Expected last event to be .completed, got \(events.last as Any)")
        }
        XCTAssertEqual(cid, messageID)
        XCTAssertEqual(payload.prompt, "a cat")
        XCTAssertEqual(payload.imageURL, imageURL)
        XCTAssertEqual(payload.modelIdentifier, "test-model")
        XCTAssertEqual(payload.generationConfig.steps, 4)

        // Persistence: placeholder updated to carry the .generatedImage part.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, messageID)
        XCTAssertEqual(stored.first?.contentParts.count, 1)
        guard case .generatedMedia(let storedPayload) = stored.first?.contentParts.first else {
            return XCTFail("Expected stored part to be .generatedMedia")
        }
        XCTAssertEqual(storedPayload.kind, .image)
        XCTAssertEqual(storedPayload.url, imageURL)
    }

    // MARK: - Test 1b: Preview events round-trip through runtime translation
    //
    // Contract-level proof that the additive `.preview` case flows
    // backend → service → runtime without an emit source: we synthesize
    // `.preview` events directly on the mock backend. Verifies the runtime
    // translates `ImageGenerationEvent.preview(step:total:image:)` into
    // `ImageRuntimeEvent.preview(messageID:step:totalSteps:image:)` keyed to
    // the placeholder, carries the in-memory bytes through unchanged, and
    // does NOT persist previews (only the terminal `.completed` writes through
    // the store).

    func test_generate_previewEvents_roundTripAndAreNotPersisted() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let imageURL = outDir.appendingPathComponent("out.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        // Two distinct preview payloads so we can assert the bytes survive
        // the translation intact and the latest one wins.
        let previewA = Data([0x01, 0x02, 0x03])
        let previewB = Data([0x0A, 0x0B, 0x0C, 0x0D])

        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 4),
            .preview(step: 2, total: 4, image: previewA),
            .preview(step: 4, total: 4, image: previewB),
            .completed(imageURL)
        ]))

        let (runtime, store, _, _) = try await makeRuntime(backend: backend)
        let sessionID = UUID()
        // previewStride opts in at the contract level; the mock backend
        // emits previews unconditionally, so this documents the knob's role
        // rather than gating the mock.
        let config = ImageGenerationConfig(
            steps: 4, width: 64, height: 64, outputDirectory: outDir, previewStride: 2
        )

        let messageID = try await runtime.generate(
            prompt: "a fox",
            config: config,
            in: sessionID
        )

        let events = try await collectEvents(from: runtime) { event in
            if case .completed = event { return true }
            if case .failed = event { return true }
            return false
        }

        // started → progress → preview → preview → completed
        XCTAssertEqual(events.count, 5)

        let previews: [(step: Int, total: Int, image: Data)] = events.compactMap { event in
            if case .preview(let id, let step, let total, let image) = event {
                XCTAssertEqual(id, messageID, "preview keyed to the wrong placeholder")
                return (step, total, image)
            }
            return nil
        }
        XCTAssertEqual(previews.count, 2)
        XCTAssertEqual(previews[0].step, 2)
        XCTAssertEqual(previews[0].total, 4)
        XCTAssertEqual(previews[0].image, previewA, "preview bytes mutated in translation")
        XCTAssertEqual(previews[1].step, 4)
        XCTAssertEqual(previews[1].image, previewB)

        // Previews are transient — only the terminal `.completed` persists.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.contentParts.count, 1)
        guard case .generatedMedia(let storedPayload) = stored.first?.contentParts.first else {
            return XCTFail("Expected stored part to be .generatedMedia")
        }
        XCTAssertEqual(storedPayload.kind, .image)
        XCTAssertEqual(storedPayload.url, imageURL)
    }

    // MARK: - Test 2: Generate without loaded model

    func test_generate_withoutLoadedModel_emitsFailed() async throws {
        // Build a service with a registered factory but no loaded model — the
        // service's `generate` will finish the stream with `.notLoaded`.
        let service = ImageGenerationService()
        let backend = MockImageBackend()
        let captured = backend
        service.registerBackendFactory(for: .mlxDiffusion) { _ in captured }
        // Do NOT call loadModel.

        let store = RuntimeMessageStore()
        let runtime = ImageGenerationRuntime(service: service, messageStore: store)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            prompt: "a dog",
            config: ImageGenerationConfig(steps: 1, width: 64, height: 64),
            in: sessionID
        )

        let events = try await collectEvents(from: runtime) { event in
            if case .failed = event { return true }
            if case .completed = event { return true }
            return false
        }

        guard case .failed(let fid, let error) = events.last else {
            return XCTFail("Expected .failed, got \(events.last as Any)")
        }
        XCTAssertEqual(fid, messageID)
        // The service surfaces `notLoaded` when no model has been loaded.
        XCTAssertTrue(
            error is ImageGenerationServiceError,
            "Expected ImageGenerationServiceError, got \(type(of: error))"
        )
    }

    // MARK: - Test 3: Cancel

    func test_cancel_emitsCancelledAndIgnoresLaterBackendEvents() async throws {
        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 100),
            .progress(step: 2, total: 100),
            .progress(step: 3, total: 100),
            // Many more steps to give cancellation time to interleave
            .progress(step: 4, total: 100),
            .progress(step: 5, total: 100),
            .completed(URL(fileURLWithPath: "/tmp/never-emitted.png"))
        ], delayPerEventNs: 50_000_000))  // 50ms per event

        let (runtime, store, _, _) = try await makeRuntime(backend: backend)
        let sessionID = UUID()

        let messageID = try await runtime.generate(
            prompt: "x",
            config: ImageGenerationConfig(steps: 100, width: 64, height: 64),
            in: sessionID
        )

        // Wait for at least the started event and one progress event before
        // cancelling — otherwise cancel races the consumer task setup.
        let task = Task { [runtime] in
            var seen: [ImageRuntimeEvent] = []
            for await event in runtime.events {
                seen.append(event)
                if case .progress = event { break }
            }
            return seen
        }
        _ = await task.value

        await runtime.cancel(messageID: messageID)

        let terminalEvents = try await collectEvents(from: runtime) { event in
            if case .cancelled = event { return true }
            if case .completed = event { return true }
            if case .failed = event { return true }
            return false
        }

        guard case .cancelled(let cid) = terminalEvents.last else {
            return XCTFail("Expected .cancelled terminal, got \(terminalEvents.last as Any)")
        }
        XCTAssertEqual(cid, messageID)

        // Placeholder is NOT updated to a .generatedImage part on cancel.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(
            stored.first?.contentParts.isEmpty ?? false,
            "Expected placeholder contentParts empty on cancel; got \(stored.first?.contentParts as Any)"
        )
    }

    // MARK: - Test 4: Multiple concurrent generations

    func test_concurrentGenerations_emitDistinctMessageIDs() async throws {
        // Two backends so each generation has its own stream. We can't run
        // two concurrent generations through one `ImageGenerationService` —
        // the service is `.loaded → .generating → .loaded` single-threaded
        // and by design two services share no state. Use two runtimes
        // backed by two services to exercise the routing invariant.
        //
        // The runtime invariant under test is event routing keyed to the
        // distinct message IDs — the runtime never writes events for one
        // ID into another's slot.
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-runtime-concurrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let urlA = outDir.appendingPathComponent("a.png")
        let urlB = outDir.appendingPathComponent("b.png")
        try Data([0x89]).write(to: urlA)
        try Data([0x89]).write(to: urlB)

        let backendA = MockImageBackend()
        backendA.setPlan(.init(events: [
            .progress(step: 1, total: 2),
            .progress(step: 2, total: 2),
            .completed(urlA)
        ]))
        let backendB = MockImageBackend()
        backendB.setPlan(.init(events: [
            .progress(step: 1, total: 2),
            .progress(step: 2, total: 2),
            .completed(urlB)
        ]))

        let (runtimeA, _, _, _) = try await makeRuntime(backend: backendA, modelIdentifier: "model-a")
        let (runtimeB, _, _, _) = try await makeRuntime(backend: backendB, modelIdentifier: "model-b")

        let sessionA = UUID()
        let sessionB = UUID()

        let idA = try await runtimeA.generate(
            prompt: "a", config: ImageGenerationConfig(steps: 2, width: 64, height: 64), in: sessionA
        )
        let idB = try await runtimeB.generate(
            prompt: "b", config: ImageGenerationConfig(steps: 2, width: 64, height: 64), in: sessionB
        )

        XCTAssertNotEqual(idA, idB, "Distinct generations must yield distinct message IDs")

        // Drain runtime A first, then runtime B. Both have already started
        // their detached consumer tasks (via `generate(...)` above), so the
        // backend streams run concurrently even though we collect events
        // serially. Avoiding `async let` keeps the test off the
        // main-actor-self sending diagnostic — what we care about is that
        // each runtime's events route to the right messageID, not that the
        // collection itself is concurrent.
        let collectedA = try await collectEvents(from: runtimeA) { e in
            if case .completed = e { return true }
            if case .failed = e { return true }
            return false
        }
        let collectedB = try await collectEvents(from: runtimeB) { e in
            if case .completed = e { return true }
            if case .failed = e { return true }
            return false
        }

        // All events from runtime A reference idA; all events from runtime
        // B reference idB. Routing invariant: events do not bleed across
        // runtimes (or, more importantly, across message IDs within one).
        for event in collectedA {
            switch event {
            case .started(let id, _), .progress(let id, _, _), .preview(let id, _, _, _),
                 .completed(let id, _), .failed(let id, _), .cancelled(let id):
                XCTAssertEqual(id, idA, "runtimeA emitted event for non-matching messageID")
            }
        }
        for event in collectedB {
            switch event {
            case .started(let id, _), .progress(let id, _, _), .preview(let id, _, _, _),
                 .completed(let id, _), .failed(let id, _), .cancelled(let id):
                XCTAssertEqual(id, idB, "runtimeB emitted event for non-matching messageID")
            }
        }

        // The completed payloads carry the right model identifiers.
        guard case .completed(_, let payloadA) = collectedA.last else {
            return XCTFail("runtime A did not complete")
        }
        guard case .completed(_, let payloadB) = collectedB.last else {
            return XCTFail("runtime B did not complete")
        }
        XCTAssertEqual(payloadA.modelIdentifier, "model-a")
        XCTAssertEqual(payloadB.modelIdentifier, "model-b")
    }

    // MARK: - Test 4b: Bare config (nil steps) reaches the backend seam honestly

    /// A bare `ImageGenerationConfig()` — the demo app's image-gen tool path,
    /// and any other caller that doesn't set `steps` explicitly — must carry
    /// `steps == nil` all the way to the backend rather than the runtime
    /// silently substituting a guessed default. This is the #2453 M2 fix:
    /// before it, `ImageGenerationConfig()` defaulted `steps` to a fixed
    /// `20`, so a distilled model (SDXL Turbo, trained for ~2 steps) ran
    /// ~10x the denoise work its preset called for.
    func test_generate_bareConfig_carriesNilStepsToBackendSeam() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-runtime-nilsteps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let imageURL = outDir.appendingPathComponent("out.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        // Simulates a backend that resolved a distilled model's own preset
        // (2 steps) since the caller left `config.steps` unset.
        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 2),
            .progress(step: 2, total: 2),
            .completed(imageURL)
        ]))

        let (runtime, _, mockBackend, _) = try await makeRuntime(backend: backend)
        let sessionID = UUID()
        let config = ImageGenerationConfig(outputDirectory: outDir)
        XCTAssertNil(config.steps, "bare ImageGenerationConfig() must leave steps nil, not default to 20")

        let messageID = try await runtime.generate(prompt: "a cat", config: config, in: sessionID)

        // The real seam check: what `ImageGenerationBackend.generate` actually
        // received, through `ImageGenerationRuntime` -> `ImageGenerationService`
        // -> the backend. Asserting only on the runtime's own pre-call
        // snapshot (below) would pass even if something in that chain
        // re-defaulted `steps` before the backend ever saw it — this line is
        // what makes the test fail if that regresses.
        //
        // Assert non-nil first: `generate(prompt:config:in:)` calls the
        // backend eagerly today, so `receivedConfig` is already populated by
        // the time we get here, and the assertion below is non-vacuous. If
        // stream construction ever went lazy (deferred until the first
        // consumer pulls an element), `receivedConfig` would still be nil at
        // this point and `XCTAssertNil(mockBackend.receivedConfig?.steps)`
        // would pass vacuously through optional chaining — this line makes
        // that failure mode loud instead of silently proving nothing.
        XCTAssertNotNil(mockBackend.receivedConfig, "the backend must have received a config by this point")
        XCTAssertNil(
            mockBackend.receivedConfig?.steps,
            "the backend must receive steps == nil, not a re-defaulted value, when the caller left it unset"
        )

        let events = try await collectEvents(from: runtime) { event in
            if case .completed = event { return true }
            if case .failed = event { return true }
            return false
        }

        guard case .progress(let pid, let step, let total) = events[1] else {
            return XCTFail("Expected second event to be the first .progress, got \(events[1])")
        }
        XCTAssertEqual(pid, messageID)
        XCTAssertEqual(step, 1)
        // The backend's reported total (2, the SDXL-Turbo-style preset) wins
        // over the absent config value — never a guessed "20".
        XCTAssertEqual(total, 2)

        guard case .completed(_, let payload) = events.last else {
            return XCTFail("Expected last event to be .completed, got \(events.last as Any)")
        }
        // The persisted snapshot is honest too: nil in, nil captured — a
        // "regenerate with the same settings" replay re-resolves the preset
        // rather than baking in whatever the backend happened to pick.
        XCTAssertNil(payload.generationConfig.steps)
    }

    /// Degenerate case: `config.steps` is nil AND the backend's first tick
    /// hasn't reported a real total yet (`total == 0`, e.g. a backend that
    /// only knows its step count once denoising starts). The runtime must
    /// fall back to the existing `0` "unknown until the first event"
    /// sentinel documented on `ImageGenerationProgress` — not a guessed
    /// default — since there is no source of truth to guess from.
    func test_generate_nilStepsAndZeroBackendTotal_resolvesToZeroSentinel() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-runtime-zerosentinel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let imageURL = outDir.appendingPathComponent("out.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 0),
            .completed(imageURL)
        ]))

        let (runtime, _, _, _) = try await makeRuntime(backend: backend)
        let sessionID = UUID()
        let config = ImageGenerationConfig(outputDirectory: outDir)

        let messageID = try await runtime.generate(prompt: "a cat", config: config, in: sessionID)

        let events = try await collectEvents(from: runtime) { event in
            if case .completed = event { return true }
            if case .failed = event { return true }
            return false
        }

        guard case .progress(let pid, _, let total) = events[1] else {
            return XCTFail("Expected second event to be the first .progress, got \(events[1])")
        }
        XCTAssertEqual(pid, messageID)
        XCTAssertEqual(total, 0, "with no config value and no backend-reported total, the runtime must report the honest 0 sentinel, not a guess")
    }

    // MARK: - Test 5: ConversationEvent case discipline
    //
    // Sentry: confirms ImageRuntimeEvent did not land as new cases on
    // ConversationEvent. ConversationEvent's case set is the load-bearing
    // contract for text-side adapters; an image-side leak would silently
    // gain unreachable switch arms in every consumer.
    //
    // Counts cases by exhaustively switching. If a future PR adds a
    // ConversationEvent case, this test must be updated deliberately —
    // which is the point.

    func test_conversationEvent_caseCount_unchangedByImageRuntime() {
        // Build one of each ConversationEvent case via a sample. We only
        // need the type-system commitment that the cases below are the
        // full set — exhaustive switch is the gate.
        let samples: [ConversationEvent] = [
            .messageInserted(ChatMessage(role: .user, content: "", sessionID: UUID())),
            .messageRemoved(messageID: UUID()),
            .messageUpdated(ChatMessage(role: .user, content: "", sessionID: UUID())),
            .sessionBranched(newSessionID: UUID(), copiedCount: 0),
            .streamStarted(messageID: UUID()),
            .tokenEmitted(messageID: UUID(), delta: ""),
            .tokenUsageRecorded(messageID: UUID(), promptTokens: 0, completionTokens: 0),
            .thinkingStarted(messageID: UUID()),
            .thinkingUpdated(messageID: UUID(), partialText: ""),
            .thinkingFinalized(messageID: UUID(), text: "", signature: nil),
            .loopDetected(messageID: UUID()),
            .streamFinished(messageID: UUID(), reason: .stop),
            .errorRaised(.cancelled),
            .sessionTouchFailed(sessionID: UUID()),
            .beforeContextAssembly(prompt: nil, request: PromptContextRequest(sessionID: UUID(), messageCount: 0, userInput: nil)),
            .historyShaped(sessionID: UUID(), diagnostics: []),
            .contextAssembled(slots: []),
            .afterGeneration(messageID: UUID(), finalText: ""),
            .compressionTriggered(removed: [], reason: .manual),
            .historyCompressed(sessionID: UUID(), insertedRecords: []),
            .toolCallRequested(ToolCall(id: "", toolName: "", arguments: "")),
            .toolCallApproved(""),
            .toolCallCompleted("", ToolResult(callId: "", content: "")),
            .agentHandoff(from: nil, to: UUID()),
            .hookFired(event: "", sessionID: UUID())
        ]
        // The exhaustive switch below is the actual test — if any new
        // case landed (e.g. an image-side leak), this fails to compile.
        for event in samples {
            switch event {
            case .messageInserted, .messageRemoved, .messageUpdated, .sessionBranched,
                 .streamStarted, .tokenEmitted, .tokenUsageRecorded,
                 .thinkingStarted, .thinkingUpdated, .thinkingFinalized,
                 .loopDetected, .streamFinished, .errorRaised, .sessionTouchFailed,
                 .beforeContextAssembly, .historyShaped, .contextAssembled, .afterGeneration,
                 .compressionTriggered, .historyCompressed, .toolCallRequested, .toolCallApproved,
                 .toolCallCompleted,
                 .agentHandoff, .hookFired:
                continue
            }
        }
        // Pin the exact case count as a runtime assertion too — the
        // sample list is the source of truth. skillInvoked removed with
        // ManifoldSkills (#2434): 26 → 25.
        XCTAssertEqual(samples.count, 25, "ConversationEvent case count drifted — image-side cases may have leaked in")
    }
}
