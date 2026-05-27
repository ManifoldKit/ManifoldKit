import Foundation

/// Owns unstructured turn tasks launched by ``ConversationTurnExecutor``.
///
/// The runtime intentionally returns a ``ConversationStreamHandle`` before
/// generation completes. This registry centralises the unstructured task
/// boundary so handles can be cancelled and completed tasks cannot linger in
/// per-runtime bookkeeping.
package final class ConversationTurnTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ConversationStreamHandle: Task<Void, Never>] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    @discardableResult
    func launch(
        handle: ConversationStreamHandle,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) async -> Task<Void, Never> {
        let gate = ConversationTurnTaskStartGate()
        let task = Task.detached(priority: priority) { [weak self] in
            await gate.wait()
            defer { self?.unregister(handle) }
            await operation()
        }

        let previous = store(task, for: handle)
        previous?.cancel()

        await gate.open()
        return task
    }

    func cancel(_ handle: ConversationStreamHandle) {
        lock.lock()
        let task = tasks[handle]
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in activeTasks {
            task.cancel()
        }
    }

    private func unregister(_ handle: ConversationStreamHandle) {
        lock.lock()
        tasks.removeValue(forKey: handle)
        lock.unlock()
    }

    private func store(
        _ task: Task<Void, Never>,
        for handle: ConversationStreamHandle
    ) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.updateValue(task, forKey: handle)
    }
}

private actor ConversationTurnTaskStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
