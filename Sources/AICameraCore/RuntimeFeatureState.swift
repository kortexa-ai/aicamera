import Foundation

/// Quick controls are independent of the saved provider/model configuration. A generation changes
/// on both edges so work admitted before Off cannot reappear after an immediate On.
public final class RuntimeFeatureState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public fileprivate(set) var transcription: Bool
        public fileprivate(set) var translation: Bool
        public fileprivate(set) var gestures: Bool
        public fileprivate(set) var translationSourceLanguage: String?
        public fileprivate(set) var translationTargetLanguage: String?
        public fileprivate(set) var captionGeneration: UInt64 = 0
        public fileprivate(set) var gestureGeneration: UInt64 = 0
        public fileprivate(set) var captionsChangedAt: TimeInterval = -.infinity
        public fileprivate(set) var gesturesChangedAt: TimeInterval = -.infinity
        public var needsTranscription: Bool { transcription || translation }
    }

    private let lock = NSLock()
    private var value: Snapshot

    public init(transcription: Bool = true, translation: Bool = true, gestures: Bool = true) {
        value = Snapshot(transcription: transcription, translation: translation, gestures: gestures)
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func set(transcription: Bool, translation: Bool, gestures: Bool,
                    translationSourceLanguage: String? = nil, translationTargetLanguage: String? = nil,
                    now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if value.transcription != transcription || value.translation != translation
            || value.translationSourceLanguage != translationSourceLanguage
            || value.translationTargetLanguage != translationTargetLanguage {
            value.captionGeneration &+= 1
            value.captionsChangedAt = now
        }
        if value.gestures != gestures {
            value.gestureGeneration &+= 1
            value.gesturesChangedAt = now
        }
        value.transcription = transcription
        value.translation = translation
        value.gestures = gestures
        value.translationSourceLanguage = translationSourceLanguage
        value.translationTargetLanguage = translationTargetLanguage
        return value
    }

    public func permitsCaptions(from origin: Snapshot) -> Bool {
        snapshot.captionGeneration == origin.captionGeneration
    }

    public func permitsGesture(capturedAt: TimeInterval) -> Bool {
        let current = snapshot
        return current.gestures && capturedAt.isFinite && capturedAt >= current.gesturesChangedAt
    }

    public func filtered(_ scene: SceneSnapshot, from origin: Snapshot) -> SceneSnapshot {
        let current = snapshot
        var visible = scene
        if current.captionGeneration != origin.captionGeneration {
            visible.transcript = nil
            visible.agentResponse = nil
        }
        if !current.needsTranscription { visible.transcript = nil }
        if !current.gestures || current.gestureGeneration != origin.gestureGeneration {
            visible.gestures = []
            visible.gestureControl = nil
        }
        return visible
    }
}

public enum CameraReadiness: Sendable {
    case needsAttention, ready, inUse

    public static func resolve(needsAttention: Bool, isInUse: Bool) -> Self {
        // Activity wins: configuration warnings remain visible in the device rows.
        if isInUse { return .inUse }
        return needsAttention ? .needsAttention : .ready
    }
}
