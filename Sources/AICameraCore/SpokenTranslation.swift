import Foundation

/// Session-only permission. Neither an agent input pause nor caption visibility owns this gate.
public final class SpokenTranslationState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public fileprivate(set) var enabled = false
        public fileprivate(set) var agentBusy = false
        public fileprivate(set) var targetLanguage = "system"
        public fileprivate(set) var sourceLanguage = "auto"
        public fileprivate(set) var generation: UInt64 = 0
        public fileprivate(set) var changedAt: TimeInterval = -.infinity
        public var acceptsMicrophone: Bool { enabled && !agentBusy }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    public init() {}
    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }

    @discardableResult
    public func set(enabled: Bool, targetLanguage: String, agentBusy: Bool, sourceLanguage: String = "auto",
                    now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if value.enabled != enabled || value.targetLanguage != targetLanguage || value.agentBusy != agentBusy
            || value.sourceLanguage != sourceLanguage {
            value.generation &+= 1
            value.changedAt = now
        }
        value.enabled = enabled; value.targetLanguage = targetLanguage; value.agentBusy = agentBusy
        value.sourceLanguage = sourceLanguage
        return value
    }

    public func permits(_ origin: Snapshot, capturedAt: TimeInterval,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let current = snapshot
        return current.acceptsMicrophone && origin.acceptsMicrophone && current.generation == origin.generation
            && capturedAt.isFinite && now.isFinite && capturedAt >= current.changedAt
            && now >= capturedAt && now - capturedAt <= 20
    }

    public func isCurrent(_ origin: Snapshot) -> Bool {
        let current = snapshot
        return current.acceptsMicrophone && origin.acceptsMicrophone && current.generation == origin.generation
    }
}

public protocol TranslationVoiceClient: Sendable {
    /// Return bounded mono PCM at its actual sample rate; never play or persist it here.
    func synthesize(text: String, language: String) async throws -> PCM16Audio
}

public struct SpokenTranslationSegment: Sendable {
    public let id: UUID
    public let text: String
    public let capturedAt: TimeInterval
    public let voice: SpokenTranslationState.Snapshot
    public let privacy: PrivacyMuteState.Snapshot

    public init?(id: UUID, outcome: TranslationOutcome, capturedAt: TimeInterval,
                 voice: SpokenTranslationState.Snapshot, privacy: PrivacyMuteState.Snapshot) {
        guard let text = outcome.translatedMicrophoneText, text.count <= 800, text.utf8.count <= 3_200,
              outcome.requestedTargetLanguage == voice.targetLanguage,
              outcome.requestedSourceLanguage == voice.sourceLanguage, capturedAt.isFinite else { return nil }
        self.id = id; self.text = text; self.capturedAt = capturedAt; self.voice = voice; self.privacy = privacy
    }
}
