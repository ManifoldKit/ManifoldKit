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

/// Sendable wrapper for a strong, lock-guarded reference to a non-Sendable class.
///
/// Used to hand the successful connection's `ConnectAddressPinningDelegate` from
/// the retry closure (which runs off the runner's task) back to the `run` catch
/// path so a mid-stream DNS-rebinding cancellation can be distinguished from a
/// user cancellation. The reference must be *strong* — a weak box could drop the
/// delegate before the catch path reads its violation flag.
final class StrongBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
