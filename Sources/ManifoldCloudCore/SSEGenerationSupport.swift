import Foundation

/// Thread-safe counter for tracking retry attempts across @Sendable closures.
final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new value (1-based).
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Sendable wrapper for a weak reference to a non-Sendable class.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}
