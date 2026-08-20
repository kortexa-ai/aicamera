import Foundation

/// A lock-based single-slot mailbox that keeps only the newest value.
///
/// Unlike `LatestValueMailbox` (async, for network stages), this slot is read
/// synchronously so real-time capture callbacks never wait on a producer. A
/// stale value is simply not returned by `fresh(maxAge:)`.
public final class LatestValueSlot<Element> {
    private let lock = NSLock()
    private var current: (element: Element, date: Date)?

    public init() {}

    /// Stores a new value, replacing any pending one.
    public func store(_ element: Element, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        current = (element, date)
    }

    /// Returns the stored value and its timestamp, or nil when empty.
    public func latest() -> (element: Element, date: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Returns the stored element only when it is younger than `maxAge`.
    public func fresh(maxAge: TimeInterval, now: Date = Date()) -> Element? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, now.timeIntervalSince(current.date) <= maxAge else { return nil }
        return current.element
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }
}
