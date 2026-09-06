import Foundation

/// A short, synchronous privacy boundary shared by capture, rendering, and asynchronous work.
/// Muting and unmuting both retire old work; unmuting never makes an old token valid again.
public final class PrivacyMuteState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let isMuted: Bool
        public let generation: UInt64
    }

    private let lock = NSLock()
    private var value: Snapshot

    public init(isMuted: Bool = false) {
        value = Snapshot(isMuted: isMuted, generation: 0)
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func setMuted(_ muted: Bool) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if muted != value.isMuted {
            value = Snapshot(isMuted: muted, generation: value.generation &+ 1)
        }
        return value
    }

    public func isCurrent(_ token: Snapshot) -> Bool { snapshot == token }
    public func permitsSpeech(_ token: Snapshot) -> Bool { !token.isMuted && isCurrent(token) }

    public func filtered(_ scene: SceneSnapshot, from token: Snapshot) -> SceneSnapshot {
        guard permitsSpeech(token) else {
            var filtered = scene
            filtered.transcript = nil
            filtered.agentResponse = nil
            return filtered
        }
        return scene
    }
}
