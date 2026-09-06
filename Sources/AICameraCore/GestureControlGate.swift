import Foundation

public enum GestureControlAction: String, Codable, Equatable, Sendable { case startAgent, mute }

/// Deliberate held gestures only. A held pose fires once and must be released before rearming.
public struct GestureControlGate: Sendable {
    public private(set) var feedback: GestureControlFeedback?
    private var candidate: GestureControlAction?
    private var beganAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval?
    private var neutralSince: TimeInterval?
    private var latched: GestureControlAction?
    private var lastTriggerAt: TimeInterval = -.infinity

    public init() {}

    public mutating func observe(
        _ gestures: [GestureObservation], capturedAt: TimeInterval, now: TimeInterval
    ) -> GestureControlAction? {
        guard capturedAt.isFinite, now.isFinite, capturedAt >= 0,
              now >= capturedAt, now - capturedAt <= 0.5,
              lastFrameAt.map({ capturedAt > $0 }) ?? true else { return nil }
        let hasGap = lastFrameAt.map { capturedAt - $0 > 0.35 } ?? true
        lastFrameAt = capturedAt
        feedback = nil
        // Recognition is useful feedback even before a pose is reliable enough to activate.
        if let pose = gestures.first, pose.confidence.isFinite, pose.confidence < 0.8,
           pose.kind == .victory || pose.kind == .closedFist {
            feedback = .init(action: pose.kind == .victory ? .startAgent : .mute,
                             progress: 0, capturedAt: capturedAt, needsClearerPose: true)
        }
        let actions = gestures.compactMap { gesture -> GestureControlAction? in
            guard gesture.confidence.isFinite, gesture.confidence >= 0.8 else { return nil }
            switch gesture.kind {
            case .victory: return .startAgent
            case .closedFist: return .mute
            default: return nil
            }
        }
        guard let action = actions.first, actions.allSatisfy({ $0 == action }) else {
            candidate = nil
            if neutralSince == nil || hasGap { neutralSince = capturedAt }
            if capturedAt - (neutralSince ?? capturedAt) >= 0.3 { latched = nil }
            return nil
        }
        neutralSince = nil
        guard latched != action else { return nil }
        if candidate != action || hasGap {
            candidate = action
            beganAt = capturedAt
        }
        feedback = .init(action: action, progress: min(1, (capturedAt - beganAt) / 0.8),
                         capturedAt: capturedAt, needsClearerPose: false)
        guard capturedAt - beganAt >= 0.8, capturedAt - lastTriggerAt >= 1 else { return nil }
        latched = action
        lastTriggerAt = capturedAt
        return action
    }
}
