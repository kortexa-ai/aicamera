import Foundation

public enum HandJoint: Hashable, Sendable {
    case wrist
    case thumbTip
    case indexTip, indexPIP, indexMCP
    case middleTip, middlePIP, middleMCP
    case ringTip, ringPIP, ringMCP
    case littleTip, littlePIP, littleMCP
}

/// Rotation-independent hand gesture classification for normalized Vision landmarks.
/// The classifier scales its thresholds to the observed palm instead of assuming that
/// an upright, similarly sized hand is always presented to the camera.
public enum HandGestureClassifier {
    /// Every required joint must be usable. A partly occluded folded fingertip must not
    /// turn the confidence of an otherwise clear hand into that one joint's confidence.
    public static func observationConfidence(_ jointConfidences: [Double]) -> Double {
        guard jointConfidences.count == 14,
              jointConfidences.allSatisfy({ $0.isFinite && (0.25...1).contains($0) }) else { return 0 }
        return jointConfidences.reduce(0, +) / Double(jointConfidences.count)
    }

    public static func classify(_ points: [HandJoint: NormalizedPoint]) -> GestureKind? {
        guard let wrist = points[.wrist],
              let thumb = points[.thumbTip],
              let index = finger(.indexTip, .indexPIP, .indexMCP, in: points),
              let middle = finger(.middleTip, .middlePIP, .middleMCP, in: points),
              let ring = finger(.ringTip, .ringPIP, .ringMCP, in: points),
              let little = finger(.littleTip, .littlePIP, .littleMCP, in: points) else {
            return nil
        }

        let palmScale = distance(wrist, middle.mcp)
        guard palmScale.isFinite, palmScale >= 0.025 else { return nil }

        if distance(thumb, index.tip) <= palmScale * 0.42 {
            return .pinch
        }

        let extended = [index, middle, ring, little].map { finger in
            distance(wrist, finger.tip) > distance(wrist, finger.pip) + palmScale * 0.16
                && distance(finger.mcp, finger.tip) > distance(finger.mcp, finger.pip) * 1.35
        }

        switch extended {
        case [true, true, false, false]:
            return .victory
        case [true, false, false, false]:
            return .pointing
        case [true, true, true, true]:
            return .openPalm
        case [false, false, false, false]:
            let maximumTipDistance = [index, middle, ring, little]
                .map { distance(wrist, $0.tip) }
                .max() ?? .infinity
            return maximumTipDistance <= palmScale * 1.75 ? .closedFist : .unknown
        default:
            return .unknown
        }
    }

    private struct Finger {
        let tip: NormalizedPoint
        let pip: NormalizedPoint
        let mcp: NormalizedPoint
    }

    private static func finger(
        _ tip: HandJoint,
        _ pip: HandJoint,
        _ mcp: HandJoint,
        in points: [HandJoint: NormalizedPoint]
    ) -> Finger? {
        guard let tipPoint = points[tip], let pipPoint = points[pip], let mcpPoint = points[mcp] else {
            return nil
        }
        return Finger(tip: tipPoint, pip: pipPoint, mcp: mcpPoint)
    }

    private static func distance(_ first: NormalizedPoint, _ second: NormalizedPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }
}
