import Foundation

/// A small, non-media presentation value shared by the menu and outgoing camera.
public enum AgentOverlayStatus: String, Codable, Sendable, CaseIterable {
    case off, connecting, listening, paused, thinking, speaking, muted, failed

    public var label: String {
        switch self {
        case .off: return "Agent off · hold ✌️"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .paused: return "Not listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .muted: return "Muted"
        case .failed: return "Agent unavailable"
        }
    }
}

public struct GestureControlFeedback: Codable, Equatable, Sendable {
    public var action: GestureControlAction
    public var progress: Double
    public var capturedAt: TimeInterval
    public var needsClearerPose: Bool
}
