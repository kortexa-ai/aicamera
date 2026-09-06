import Foundation

public enum GestureControlAction: Equatable, Sendable { case startAgent, mute }

/// Deliberate held gestures only. A held pose fires once and must be released before rearming.
public struct GestureControlGate: Sendable {
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
        guard capturedAt - beganAt >= 0.8, capturedAt - lastTriggerAt >= 1 else { return nil }
        latched = action
        lastTriggerAt = capturedAt
        return action
    }
}
