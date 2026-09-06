import Foundation

public enum AgentListeningMode: String, Codable, CaseIterable, Sendable {
    case conversation
    case oneQuestion

    public var title: String {
        switch self {
        case .conversation: return "Conversation"
        case .oneQuestion: return "One question at a time"
        }
    }
}

/// User intent is independent of transport response/playback state and of the call microphone.
public struct AgentListeningPolicy: Equatable, Sendable {
    public private(set) var mode: AgentListeningMode = .conversation
    public private(set) var requested = false

    public init() {}
    public mutating func start(mode: AgentListeningMode) { self.mode = mode; requested = true }
    public mutating func setRequested(_ value: Bool) { requested = value }
    public mutating func utteranceEnded() { if mode == .oneQuestion { requested = false } }
    public mutating func stop() { requested = false }
}

/// The capture callback checks this gate before handing PCM to the agent transport.
/// Closing it never mutes the separate audio path to a calling app.
public final class AgentInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armedAt: TimeInterval?

    public init() {}

    public func open(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        armedAt = time.isFinite ? time : nil
    }

    public func close() {
        lock.lock(); armedAt = nil; lock.unlock()
    }

    public func admits(capturedAt time: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let armedAt, time.isFinite else { return false }
        return time >= armedAt
    }
}
