import Foundation

/// A single-slot async mailbox. New values replace stale pending work instead of building latency.
public actor LatestValueMailbox<Element: Sendable> {
    private var pending: Element?
    private var waiter: CheckedContinuation<Element?, Never>?
    private var finished = false
    private(set) public var replacedCount: UInt64 = 0

    public init() {}

    public func submit(_ element: Element) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: element)
        } else {
            if pending != nil { replacedCount += 1 }
            pending = element
        }
    }

    public func next() async -> Element? {
        guard !finished else { return nil }
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        pending = nil
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }
}
