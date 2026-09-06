import Foundation
import CoreGraphics

public struct AgentCameraInsetRequest: Equatable, Sendable {
    public let position: AgentCardPosition
    /// Fraction of output width, not area. Height follows the camera output aspect ratio.
    public let widthFraction: Double
    public let ttlSeconds: Double

    public init?(position: AgentCardPosition = .lowerRight, widthFraction: Double = 0.2, ttlSeconds: Double = 30) {
        guard widthFraction.isFinite, (0.15...0.5).contains(widthFraction),
              ttlSeconds.isFinite, (1...300).contains(ttlSeconds) else { return nil }
        self.position = position; self.widthFraction = widthFraction; self.ttlSeconds = ttlSeconds
    }

    /// Top-left origin, matching native captions. Reserve status/caption margins and preserve aspect.
    public func frame(in size: CGSize) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 100, size.height >= 180 else { return nil }
        let margin: CGFloat = max(14, size.width * 0.02)
        let top: CGFloat = max(56, size.height * 0.1) + 182
        let bottom: CGFloat = max(108, size.height * 0.15)
        let scale: CGFloat = min(CGFloat(widthFraction), (size.height - top - bottom) / size.height)
        let width: CGFloat = size.width * scale
        let height: CGFloat = size.height * scale
        guard width >= 60, height >= 40 else { return nil }
        let right = position == .upperRight || position == .lowerRight
        let lower = position == .lowerLeft || position == .lowerRight
        let x: CGFloat = right ? size.width - margin - width : margin
        let y: CGFloat = lower ? size.height - bottom - height : top
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum AgentCameraLayout: Equatable, Sendable {
    case camera
    case inset(AgentCameraInsetRequest)
    /// Expiration suppresses the scene immediately, before the UI cleanup task runs.
    case expired
}

public struct AgentCameraInset: Equatable, Sendable {
    public let id: UUID
    public let request: AgentCameraInsetRequest
    public let expiresAt: TimeInterval
}
