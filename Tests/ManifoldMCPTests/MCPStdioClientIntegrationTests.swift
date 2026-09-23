import Darwin
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldTestSupport

#if os(macOS) && !targetEnvironment(macCatalyst)
final class MCPStdioClientIntegrationTests: XCTestCase {
    func test_lineDelimitedPeerInitializesAndListsTools() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(pidPath) }
        let client = MCPClient()

        let source = try await withTimeout(.seconds(5)) { try await client.connect(descriptor) }
        try await source.refreshTools()
        let toolNames = await source.currentToolNames()
        let serverIDs = await client.sources().map(\.serverID)
        XCTAssertEqual(toolNames, ["echo"])
        XCTAssertEqual(serverIDs, [descriptor.id])

        await client.disconnect(serverID: descriptor.id)
        let pid = try await readPID(pidPath)
        try await assertExited(pid)
    }

    func test_delayedChildStartupDoesNotConsumeInitializeBudget() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "delayed_start", initializationTimeout: .seconds(2))
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        // This fixture waits four seconds before entering its protocol loop.
        // Prepare it first so the two-second initialize budget measures MCP,
        // not interpreter launch or test-runner scheduling.
        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        let source = try await client.connect(descriptor)
        try await source.refreshTools()
        let names = await source.currentToolNames()
        XCTAssertEqual(names, ["echo"])
        await client.disconnect(serverID: descriptor.id)
        try await assertExited(pid)
    }

    func test_unexpectedEOFRemovesSourceAndReportsTransportClosedOnce() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "exit_after_initialize")
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }

        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        _ = try await client.connect(descriptor)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        await client.disconnect(serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .disconnected(_, .transportClosed) = terminal.first else {
            return XCTFail("Unexpected EOF should report transportClosed: \(terminal)")
        }
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await assertExited(pid)
    }

    func test_malformedOutputRemovesSourceAndReportsFailureOnce() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "malformed_after_initialize")
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }

        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        _ = try await client.connect(descriptor)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        await client.disconnect(serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .disconnected(_, .failed(let detail)) = terminal.first else {
            return XCTFail("Malformed output should report a failure: \(terminal)")
        }
        XCTAssertFalse(detail.isEmpty)
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await assertExited(pid)
    }

    func test_initializeTimeoutClosesProvisionalProcessAndReportsOneError() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "silent", initializationTimeout: .milliseconds(200))
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }

        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        do {
            _ = try await withTimeout(.seconds(5)) { try await client.connect(descriptor) }
            XCTFail("Expected initialize timeout")
        } catch let error as MCPError {
            XCTAssertEqual(error, .requestTimeout)
        }
        try await assertExited(pid)
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .error(_, .requestTimeout) = terminal.first else {
            return XCTFail("Timeout should report requestTimeout: \(terminal)")
        }
    }

    func test_exitAtInitializedBoundaryNeverRetainsAClosedSource() async throws {
        // The child exits as soon as it reads notifications/initialized. That
        // races session.start's ready transition and connect's source publish.
        for _ in 0..<5 {
            let (descriptor, pidPath) = try makeDescriptor(mode: "exit_on_initialized")
            defer { removeMarker(pidPath) }
            let client = MCPClient()
            let recorder = MCPEventRecorder()
            let collector = recordEvents(from: client, into: recorder)
            defer { collector.cancel() }
            let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)

            do {
                _ = try await withTimeout(.seconds(4)) { try await client.connect(descriptor) }
            } catch let error as MCPError {
                switch error {
                case .transportClosed, .transportFailure: break
                default: XCTFail("Unexpected early-exit error: \(error)")
                }
            }
            try await waitForTerminalEvent(recorder, serverID: descriptor.id)
            await client.disconnect(serverID: descriptor.id)
            let sources = await client.sources()
            XCTAssertTrue(sources.isEmpty)
            let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
            XCTAssertEqual(events.filter { $0.isTerminal(for: descriptor.id) }.count, 1)
            try await assertExited(pid)
        }
    }

    func test_cancelInitializeClosesProvisionalProcessAndReportsOneError() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "silent_ignore_termination", initializationTimeout: .seconds(10))
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }

        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        let connectTask = Task { try await client.connect(descriptor) }
        try await waitForInitializeReceived(at: pidPath)
        connectTask.cancel()
        do {
            _ = try await withTimeout(.seconds(5)) { try await connectTask.value }
            XCTFail("Expected cancelled initialize")
        } catch let error as MCPError {
            XCTAssertEqual(error, .cancelled)
        }
        // The child ignores SIGTERM, so cleanup must wait for the bounded
        // SIGKILL path. The PID must already be gone when connect returns.
        XCTAssertNotEqual(kill(pid, 0), 0, "connect returned before process teardown completed")
        try await assertExited(pid)
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .error(_, .cancelled) = terminal.first else {
            return XCTFail("Cancellation should report cancelled: \(terminal)")
        }
    }

    func test_disconnectDuringInitializeClosesProvisionalProcessOnce() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "silent", initializationTimeout: .seconds(10))
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }

        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)
        let connectTask = Task { try await client.connect(descriptor) }
        try await waitForInitializeReceived(at: pidPath)
        await client.disconnect(serverID: descriptor.id)
        do {
            _ = try await withTimeout(.seconds(5)) { try await connectTask.value }
            XCTFail("A disconnected provisional session must not connect")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        }
        try await assertExited(pid)
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .disconnected(_, .requested) = terminal.first else {
            return XCTFail("Explicit disconnect should report requested once: \(terminal)")
        }
    }

    func test_closeDuringConnectingHookCannotSpawnAfterCleanup() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(pidPath) }
        guard case .stdio(let command) = descriptor.transport else {
            return XCTFail("Expected stdio fixture")
        }
        let gate = MCPBoundaryGate()
        let transport = MCPStdioTransport(command: command, maxMessageBytes: 4_096)
        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: MCPJSONRPCCodec(maxMessageBytes: 4_096, maxJSONNestingDepth: 8),
            requestTimeout: .seconds(10),
            maxConcurrentRequests: 1,
            stateHook: MCPConnectingGateHook(gate: gate)
        )

        let start = Task { try await session.start() }
        try await withTimeout(.seconds(3)) { await gate.waitUntilParked() }
        await session.close()
        await gate.release()
        do {
            _ = try await withTimeout(.seconds(3)) { try await start.value }
            XCTFail("Closed session must not start a child")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath.path))
        do {
            try await transport.start()
            XCTFail("Closed transport must reject a late start")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        }
        await transport.close()
    }

    func test_closeCallbackBeforePublicationCannotPublishDeadSource() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(pidPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }
        let pid = try await prepareClientTransport(for: descriptor, pidPath: pidPath, client: client)

        // Suspend connect at the actor hop after isClosed, then deliver the
        // session callback before publication. This is the race a fast child
        // can produce without relying on a timing-sensitive sleep.
        await client.setBeforePublicationForTesting { serverID, attemptID in
            await client.handleSessionClosed(
                serverID: serverID, attemptID: attemptID, reason: .transportClosed
            )
        }
        do {
            _ = try await client.connect(descriptor)
            XCTFail("A closed provisional attempt must never publish a source")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        }
        await client.setBeforePublicationForTesting(nil)
        try await assertExited(pid)
        let sources = await client.sources()
        XCTAssertTrue(sources.isEmpty)
        try await waitForTerminalEvent(recorder, serverID: descriptor.id)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let terminal = events.filter { $0.isTerminal(for: descriptor.id) }
        XCTAssertEqual(terminal.count, 1)
        guard case .error(_, .transportClosed) = terminal.first else {
            return XCTFail("Provisional EOF should report transportClosed once: \(terminal)")
        }
    }

    func test_closedAttemptCannotRemoveOrReportAfterReplacementConnects() async throws {
        let (oldDescriptor, oldPIDPath) = try makeDescriptor(mode: "normal")
        let (replacementDescriptor, replacementPIDPath) = try makeDescriptor(
            mode: "normal", id: oldDescriptor.id
        )
        defer { removeMarker(oldPIDPath); removeMarker(replacementPIDPath) }
        let client = MCPClient()
        let recorder = MCPEventRecorder()
        let collector = recordEvents(from: client, into: recorder)
        defer { collector.cancel() }
        let gate = MCPBoundaryGate()
        let oldPID = try await prepareClientTransport(for: oldDescriptor, pidPath: oldPIDPath, client: client)

        await client.setBeforePublicationForTesting { serverID, attemptID in
            await client.handleSessionClosed(
                serverID: serverID, attemptID: attemptID, reason: .transportClosed
            )
            await gate.parkOnce()
        }
        let oldConnect = Task { try await client.connect(oldDescriptor) }
        try await withTimeout(.seconds(3)) { await gate.waitUntilParked() }
        await client.setBeforePublicationForTesting(nil)

        let replacementPID = try await prepareClientTransport(
            for: replacementDescriptor, pidPath: replacementPIDPath, client: client
        )
        let replacement = try await client.connect(replacementDescriptor)
        await gate.release()
        do {
            _ = try await oldConnect.value
            XCTFail("The closed attempt must not publish")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        }
        try await assertExited(oldPID)
        try await replacement.refreshTools()
        let liveIDs = await client.sources().map(\.serverID)
        XCTAssertEqual(liveIDs, [oldDescriptor.id])

        await client.disconnect(serverID: oldDescriptor.id)
        try await assertExited(replacementPID)
        let events = await drainedEvents(client: client, collector: collector, recorder: recorder)
        let relevant = events.filter {
            switch $0 {
            case .connected(let id, _), .disconnected(let id, _), .error(let id, _):
                return id == oldDescriptor.id
            default: return false
            }
        }
        guard relevant.count == 3 else {
            return XCTFail("Old cleanup must not report after replacement connects: \(relevant)")
        }
        guard case .error(_, .transportClosed) = relevant[0],
              case .connected = relevant[1],
              case .disconnected(_, .requested) = relevant[2] else {
            return XCTFail("Old terminal event must precede replacement connected: \(relevant)")
        }
    }

    func test_disconnectAllDoesNotRemoveConnectionStartedDuringCleanup() async throws {
        let (oldDescriptor, oldPIDPath) = try makeDescriptor(mode: "normal")
        let (newDescriptor, newPIDPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(oldPIDPath); removeMarker(newPIDPath) }
        let client = MCPClient()
        let gate = MCPBoundaryGate()
        let oldPID = try await prepareClientTransport(for: oldDescriptor, pidPath: oldPIDPath, client: client)
        _ = try await client.connect(oldDescriptor)
        await client.setAfterDisconnectAllSnapshotForTesting { await gate.parkOnce() }

        let disconnectTask = Task { await client.disconnectAll() }
        try await withTimeout(.seconds(3)) { await gate.waitUntilParked() }
        let newPID = try await prepareClientTransport(for: newDescriptor, pidPath: newPIDPath, client: client)
        _ = try await client.connect(newDescriptor)
        await gate.release()
        await disconnectTask.value
        await client.setAfterDisconnectAllSnapshotForTesting(nil)

        let serverIDs = await client.sources().map(\.serverID)
        XCTAssertEqual(serverIDs, [newDescriptor.id])
        try await assertExited(oldPID)
        await client.disconnect(serverID: newDescriptor.id)
        try await assertExited(newPID)
    }

    func test_cancellationBeforeRequestRegistrationResumesPromptlyAndKeepsSlotFree() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(pidPath) }
        let gate = MCPBoundaryGate()
        let (transport, pid) = try await prepareTransport(for: descriptor, pidPath: pidPath)
        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: MCPJSONRPCCodec(maxMessageBytes: 4_096, maxJSONNestingDepth: 8),
            requestTimeout: .seconds(10),
            maxConcurrentRequests: 1,
            beforeRequestRegistration: { method in
                if method == "tools/list" { await gate.parkOnce() }
            }
        )
        _ = try await session.start()

        let request = Task { try await session.sendRequest(method: "tools/list", params: nil) }
        try await withTimeout(.seconds(3)) { await gate.waitUntilParked() }
        request.cancel()
        try await withTimeout(.seconds(3)) {
            while await session.deferredRequestTerminationCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await gate.release()
        do {
            _ = try await withTimeout(.seconds(3)) { try await request.value }
            XCTFail("Cancellation before registration must resume the request")
        } catch is CancellationError {
            // The caller received cancellation without waiting for the 10 s request timeout.
        }
        let deferredCount = await session.deferredRequestTerminationCount
        XCTAssertEqual(deferredCount, 0)

        // The cancelled request must not consume the one available slot.
        _ = try await session.sendRequest(method: "tools/list", params: nil)
        await session.close()
        try await assertExited(pid)
    }

    func test_precancelledSteadyStateRequestNeverRegisters() async throws {
        let (descriptor, pidPath) = try makeDescriptor(mode: "normal")
        defer { removeMarker(pidPath) }
        let (transport, pid) = try await prepareTransport(for: descriptor, pidPath: pidPath)
        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: MCPJSONRPCCodec(maxMessageBytes: 4_096, maxJSONNestingDepth: 8),
            requestTimeout: .seconds(10),
            maxConcurrentRequests: 1
        )
        _ = try await session.start()
        let gate = MCPBoundaryGate()
        let request = Task {
            await gate.parkOnce()
            return try await session.sendRequest(method: "tools/list", params: nil)
        }
        try await withTimeout(.seconds(3)) { await gate.waitUntilParked() }
        request.cancel()
        await gate.release()
        do {
            _ = try await withTimeout(.seconds(3)) { try await request.value }
            XCTFail("A pre-cancelled request must fail immediately")
        } catch is CancellationError {
            // Task.checkCancellation prevents a request ID or pending slot.
        }
        let deferredCount = await session.deferredRequestTerminationCount
        XCTAssertEqual(deferredCount, 0)
        _ = try await session.sendRequest(method: "tools/list", params: nil)
        await session.close()
        try await assertExited(pid)
    }

    private func makeDescriptor(
        mode: String,
        id: UUID = UUID(),
        initializationTimeout: Duration = .seconds(3)
    ) throws -> (MCPServerDescriptor, URL) {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/usr/bin/python3"),
            "The process-backed stdio fixture requires macOS /usr/bin/python3"
        )
        let script = try XCTUnwrap(Bundle.module.url(
            forResource: "stdio-reference-server", withExtension: "py", subdirectory: "Fixtures"
        ))
        let pidPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-stdio-\(UUID().uuidString).pid")
        let descriptor = MCPServerDescriptor(
            id: id,
            displayName: "Line peer",
            transport: .stdio(.executable(
                at: URL(fileURLWithPath: "/usr/bin/python3"),
                args: ["-u", script.path, mode, pidPath.path]
            )),
            initializationTimeout: initializationTimeout,
            dataDisclosure: "test",
            allowsSTDIOTransport: true,
            isUnauthenticatedUnsafe: true
        )
        return (descriptor, pidPath)
    }

    private func readPID(_ path: URL) async throws -> Int32 {
        try await withTimeout(.seconds(3)) {
            while true {
                if let text = try? String(contentsOf: path, encoding: .ascii),
                   let pid = Int32(text) { return pid }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func prepareTransport(
        for descriptor: MCPServerDescriptor,
        pidPath: URL
    ) async throws -> (MCPStdioTransport, Int32) {
        guard case .stdio(let command) = descriptor.transport else {
            throw MCPError.transportFailure("Expected stdio fixture")
        }
        let transport = MCPStdioTransport(command: command, maxMessageBytes: 4_096)
        do {
            try await transport.start()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(15)
            while true {
                if let text = try? String(contentsOf: pidPath, encoding: .ascii),
                   let pid = Int32(text) {
                    addTeardownBlock { await transport.close() }
                    return (transport, pid)
                }
                guard await transport.launchedProcessIsRunningForTesting else {
                    throw MCPError.transportFailure("stdio fixture exited before writing its ready marker")
                }
                guard clock.now < deadline else {
                    throw MCPError.transportFailure("stdio fixture did not reach its ready marker")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            await transport.close()
            throw error
        }
    }

    private func prepareClientTransport(
        for descriptor: MCPServerDescriptor,
        pidPath: URL,
        client: MCPClient
    ) async throws -> Int32 {
        let (transport, pid) = try await prepareTransport(for: descriptor, pidPath: pidPath)
        guard case .stdio(let command) = descriptor.transport else {
            throw MCPError.transportFailure("Expected stdio fixture")
        }
        await client.usePrestartedStdioTransportForTesting(transport, command: command)
        return pid
    }

    private func waitForInitializeReceived(at pidPath: URL) async throws {
        let marker = URL(fileURLWithPath: pidPath.path + ".initialized")
        try await withTimeout(.seconds(3)) {
            while !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func assertExited(_ pid: Int32) async throws {
        try await withTimeout(.seconds(4)) {
            while kill(pid, 0) == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func removeMarker(_ path: URL) {
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.removeItem(at: path)
            } catch let cleanupError where (cleanupError as NSError).code == NSFileNoSuchFileError {
                // An early process exit may race the existence check.
            } catch let cleanupError {
                XCTFail("Could not remove process marker: \(cleanupError)")
            }
        }
        let initialized = URL(fileURLWithPath: path.path + ".initialized")
        if FileManager.default.fileExists(atPath: initialized.path) {
            do {
                try FileManager.default.removeItem(at: initialized)
            } catch {
                XCTFail("Could not remove initialize marker: \(error)")
            }
        }
    }

    private func recordEvents(from client: MCPClient, into recorder: MCPEventRecorder) -> Task<Void, Never> {
        Task {
            for await event in client.connectionEvents {
                await recorder.append(event)
            }
        }
    }

    private func waitForTerminalEvent(_ recorder: MCPEventRecorder, serverID: UUID) async throws {
        try await withTimeout(.seconds(5)) {
            while await recorder.events.contains(where: { $0.isTerminal(for: serverID) }) == false {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func drainedEvents(
        client: MCPClient,
        collector: Task<Void, Never>,
        recorder: MCPEventRecorder
    ) async -> [MCPConnectionEvent] {
        // Finishing the producer queues end-of-stream after every yielded event.
        // Joining the sole consumer then proves the count over the full stream,
        // including a second terminal event that may still be buffered.
        await client.finishConnectionEventsForTesting()
        await collector.value
        return await recorder.events
    }
}

private actor MCPEventRecorder {
    private(set) var events: [MCPConnectionEvent] = []
    func append(_ event: MCPConnectionEvent) { events.append(event) }
}

private actor MCPBoundaryGate {
    private var parked = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func parkOnce() async {
        guard !parked else { return }
        parked = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilParked() async {
        if parked { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct MCPConnectingGateHook: MCPSessionStateHook {
    let gate: MCPBoundaryGate

    func sessionDidTransition(_ state: MCPSessionState) async {
        if state == .connecting { await gate.parkOnce() }
    }

    func sessionDidSend(_ message: MCPJSONRPCMessage) async { _ = message }
    func sessionDidReceive(_ message: MCPJSONRPCMessage) async { _ = message }
}

private extension MCPConnectionEvent {
    func isTerminal(for serverID: UUID) -> Bool {
        switch self {
        case .disconnected(let id, _), .error(let id, _): return id == serverID
        default: return false
        }
    }
}
#endif
