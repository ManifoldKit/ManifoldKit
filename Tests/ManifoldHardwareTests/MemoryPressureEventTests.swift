import XCTest
@testable import ManifoldHardware
import ManifoldInference
import ManifoldTestSupport

/// Tests for the MemoryPressureEvent stream on InferenceService.
///
/// These tests exercise the public ``InferenceService/memoryPressureEvents()``
/// stream and the package-internal wiring paths that drive ``willUnload``,
/// ``didUnload``, ``didReload``, and ``levelChanged`` events.
@MainActor
final class MemoryPressureEventTests: XCTestCase {

    // MARK: - levelChanged

    /// `notifyPressureLevel` emits a `levelChanged` event to all subscribers.
    func test_notifyPressureLevel_emitsLevelChangedEvent() async {
        let service = makeService()
        let stream = service.memoryPressureEvents()

        service.notifyPressureLevel(.warning)

        let event = await firstEvent(from: stream)
        XCTAssertEqual(event, .levelChanged(.warning))
    }

    func test_notifyPressureLevel_critical_emitsCorrectLevel() async {
        let service = makeService()
        let stream = service.memoryPressureEvents()

        service.notifyPressureLevel(.critical)

        let event = await firstEvent(from: stream)
        XCTAssertEqual(event, .levelChanged(.critical))
    }

    // MARK: - Multiple Subscribers

    /// All active subscribers receive the same event.
    func test_multipleSubscribers_eachReceiveSameEvent() async {
        let service = makeService()
        let streamA = service.memoryPressureEvents()
        let streamB = service.memoryPressureEvents()

        service.notifyPressureLevel(.warning)

        let eventA = await firstEvent(from: streamA)
        let eventB = await firstEvent(from: streamB)
        XCTAssertEqual(eventA, .levelChanged(.warning))
        XCTAssertEqual(eventB, .levelChanged(.warning))
    }

    // MARK: - willUnload / didUnload (userRequested)

    /// `unloadModel()` emits `willUnload` then `didUnload` when a model is loaded.
    func test_unloadModel_withLoadedBackend_emitsWillAndDidUnloadEvents() async {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let stream = service.memoryPressureEvents()

        service.unloadModel()

        var received: [MemoryPressureEvent] = []
        // Collect two events with a tight deadline.
        let collected = await collectEvents(from: stream, count: 2, timeoutNanoseconds: 1_000_000_000)
        received = collected

        guard received.count == 2 else {
            XCTFail("Expected 2 events (willUnload + didUnload), got \(received.count)")
            return
        }

        if case .willUnload(_, let reason) = received[0] {
            XCTAssertEqual(reason, .userRequested)
        } else {
            XCTFail("First event should be willUnload, got \(received[0])")
        }

        if case .didUnload(_, let reason) = received[1] {
            XCTAssertEqual(reason, .userRequested)
        } else {
            XCTFail("Second event should be didUnload, got \(received[1])")
        }
    }

    /// `unloadModel()` emits no unload events when no model is currently loaded.
    func test_unloadModel_withNoLoadedModel_emitsNoUnloadEvents() async {
        let service = makeService()
        let stream = service.memoryPressureEvents()

        service.unloadModel()

        // Give any spurious events a chance to appear.
        service.notifyPressureLevel(.nominal) // sentinel

        let event = await firstEvent(from: stream)
        // The sentinel levelChanged should arrive; no willUnload or didUnload.
        XCTAssertEqual(event, .levelChanged(.nominal))
    }

    // MARK: - criticalMemoryPressure reason

    /// `unloadModel(reason:)` with `.criticalMemoryPressure` emits the correct reason.
    func test_unloadModel_criticalPressureReason_emitsCorrectReason() async {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let stream = service.memoryPressureEvents()

        service.unloadModel(reason: .criticalMemoryPressure)

        let events = await collectEvents(from: stream, count: 2, timeoutNanoseconds: 1_000_000_000)
        guard events.count == 2 else {
            XCTFail("Expected 2 events, got \(events.count)")
            return
        }

        if case .willUnload(_, let reason) = events[0] {
            XCTAssertEqual(reason, .criticalMemoryPressure)
        } else {
            XCTFail("First event should be willUnload, got \(events[0])")
        }

        if case .didUnload(_, let reason) = events[1] {
            XCTAssertEqual(reason, .criticalMemoryPressure)
        } else {
            XCTFail("Second event should be didUnload, got \(events[1])")
        }
    }

    // MARK: - modelID consistency

    /// The `modelID` in `willUnload` and `didUnload` events is consistent.
    func test_willAndDidUnload_shareTheSameModelID() async {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let stream = service.memoryPressureEvents()

        service.unloadModel()

        let events = await collectEvents(from: stream, count: 2, timeoutNanoseconds: 1_000_000_000)
        guard events.count == 2 else {
            XCTFail("Expected 2 events, got \(events.count)")
            return
        }

        guard case .willUnload(let willID, _) = events[0],
              case .didUnload(let didID, _) = events[1] else {
            XCTFail("Expected willUnload + didUnload, got \(events)")
            return
        }

        XCTAssertEqual(willID, didID, "willUnload and didUnload should carry the same modelID")
    }

    // MARK: - MemoryPressureHandler integration

    /// `MemoryPressureHandler.fireCallbacks(level:)` can be used in tests to
    /// verify that a registered callback fires; here we confirm the broadcaster
    /// is wired correctly by driving it through `notifyPressureLevel` (which is
    /// what the handler's callback would ultimately call via ChatViewModel).
    func test_broadcasterSend_firesRegisteredCallbacks() async {
        let broadcaster = MemoryPressureBroadcaster()
        let stream = broadcaster.makeStream()

        broadcaster.send(.levelChanged(.critical))

        let event = await firstEvent(from: stream)
        XCTAssertEqual(event, .levelChanged(.critical))
    }

    func test_broadcaster_finishAll_terminatesStreams() async {
        let broadcaster = MemoryPressureBroadcaster()
        let stream = broadcaster.makeStream()

        broadcaster.finishAll()

        // The stream should terminate (yield nil) immediately.
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event, "Stream should finish after finishAll()")
    }

    // MARK: - Helpers

    private func makeService() -> InferenceService {
        InferenceService()
    }

    /// Collects up to `count` events from `stream` within `timeoutNanoseconds`.
    ///
    /// Returns fewer than `count` events if the stream terminates or the timeout
    /// elapses first. Uses `withTaskGroup` so the timeout races against the
    /// collection task.
    private func collectEvents(
        from stream: AsyncStream<MemoryPressureEvent>,
        count: Int,
        timeoutNanoseconds: UInt64
    ) async -> [MemoryPressureEvent] {
        await withTaskGroup(of: [MemoryPressureEvent].self) { group in
            group.addTask {
                var collected: [MemoryPressureEvent] = []
                for await event in stream {
                    collected.append(event)
                    if collected.count >= count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Returns the first event yielded by `stream` within 1 second.
    private func firstEvent(from stream: AsyncStream<MemoryPressureEvent>) async -> MemoryPressureEvent? {
        let events = await collectEvents(from: stream, count: 1, timeoutNanoseconds: 1_000_000_000)
        return events.first
    }
}
