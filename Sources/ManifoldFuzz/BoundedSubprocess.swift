import Darwin
import Foundation
import ManifoldInference

/// Runs a short-lived subprocess with a hard wall-clock timeout, killing the
/// full process tree (not just the direct child) if it hangs.
///
/// Ported in spirit from leet-llm's out-of-process runner protocol
/// (`ChildProcess.run`): `HarnessMetadata` and `Replayer` shell out to `git`/
/// `swift` for metadata probes that should never legitimately run long, but
/// previously called `Process.waitUntilExit()` with no timeout at all — a
/// wedged git index lock or a stalled `swift --version` invocation blocked
/// the fuzz harness forever. This bounds that wait and reclaims the whole
/// descendant tree (not just the direct child), mirroring leet-llm's
/// `proc_listchildpids` walk.
///
/// Drains stdout/stderr concurrently on background queues rather than
/// reading after `waitUntilExit()`/termination — a pipe's kernel buffer is a
/// few tens of KiB; a child that writes more than that before exiting would
/// otherwise block on `write()` forever while nothing is reading the other
/// end, turning EVERY such invocation into a guaranteed timeout regardless of
/// how fast the child actually finished. Current call sites (`git`, `swift
/// --version`) emit a handful of bytes, but this is a shared wrapper, so it
/// drains both pipes unconditionally rather than relying on callers staying
/// small forever.
enum BoundedSubprocess {
    struct Result {
        /// Captured stdout. `nil` when the process failed to launch, or when
        /// it was killed for exceeding the timeout — callers should treat
        /// both the same as "probe failed," since a killed process's partial
        /// output isn't trustworthy for a metadata probe.
        let output: String?
        let timedOut: Bool
    }

    /// - Parameters:
    ///   - timeout: wall-clock budget, in seconds. The process (and any
    ///     descendants) are force-killed once this elapses.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            let argline = ([executableURL.path] + arguments).joined(separator: " ")
            let msg = "BoundedSubprocess.run: spawn failed for `\(argline)`: \(error)"
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return Result(output: nil, timedOut: false)
        }

        let stdoutCollector = OutputCollector()
        let readers = DispatchGroup()
        startDraining(stdoutPipe.fileHandleForReading, into: stdoutCollector, group: readers)
        startDraining(stderrPipe.fileHandleForReading, into: OutputCollector(), group: readers)

        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            let argline = ([executableURL.path] + arguments).joined(separator: " ")
            Log.inference.error("BoundedSubprocess.run: `\(argline, privacy: .public)` exceeded \(timeout, privacy: .public)s, killing process tree")
            terminateProcessTree(rootProcessID: process.processIdentifier)
            // Best-effort grace period for the termination handler to fire;
            // we don't block indefinitely on it either way.
            _ = terminated.wait(timeout: .now() + 0.5)
            // Killing the process closes both pipes' write ends, which
            // unblocks the reader threads' `read()` calls promptly — this
            // wait is bounded in practice, not indefinite.
            readers.wait()
            return Result(output: nil, timedOut: true)
        }

        readers.wait()
        let data = stdoutCollector.snapshot()
        return Result(output: String(data: data, encoding: .utf8), timedOut: false)
    }

    /// Reads a pipe to EOF on a background queue, appending into `collector`.
    /// Runs concurrently with the parent waiting on `terminated` so the child
    /// is never blocked on a full pipe buffer.
    private static func startDraining(
        _ handle: FileHandle,
        into collector: OutputCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collector.append(chunk)
            }
        }
    }

    private static func terminateProcessTree(rootProcessID: pid_t) {
        let descendants = descendantProcessIDs(of: rootProcessID)
        for processID in descendants.reversed() {
            kill(processID, SIGKILL)
        }
        kill(rootProcessID, SIGKILL)
    }

    private static func descendantProcessIDs(of rootProcessID: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []
        var pending = [rootProcessID]
        var visited = Set([rootProcessID])

        while let parentProcessID = pending.popLast() {
            for childProcessID in childProcessIDs(of: parentProcessID)
            where visited.insert(childProcessID).inserted {
                descendants.append(childProcessID)
                pending.append(childProcessID)
            }
        }
        return descendants
    }

    private static func childProcessIDs(of parentProcessID: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parentProcessID, nil, 0)
        guard capacity > 0 else { return [] }

        var processIDs = [pid_t](repeating: 0, count: Int(capacity))
        let count = processIDs.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parentProcessID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return processIDs.prefix(Int(count)).filter { $0 > 0 }
    }
}

/// Thread-safe accumulator for a background-drained pipe.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}
