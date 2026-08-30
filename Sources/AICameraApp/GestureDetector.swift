import AICameraCore
import CoreVideo
import Foundation
import ImageIO
import Vision

final class GestureDetector {
    func detect(in pixelBuffer: CVPixelBuffer, mirrored: Bool) -> [GestureObservation] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            return try request.results?.compactMap { try classify($0, mirrored: mirrored) } ?? []
        } catch {
            return []
        }
    }

    private func classify(_ hand: VNHumanHandPoseObservation, mirrored: Bool) throws -> GestureObservation? {
        let points = try hand.recognizedPoints(.all)
        func point(_ joint: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let value = points[joint], value.confidence >= 0.25 else { return nil }
            return value
        }
        guard let wrist = point(.wrist),
              let thumb = point(.thumbTip),
              let index = point(.indexTip), let indexPIP = point(.indexPIP), let indexMCP = point(.indexMCP),
              let middle = point(.middleTip), let middlePIP = point(.middlePIP), let middleMCP = point(.middleMCP),
              let ring = point(.ringTip), let ringPIP = point(.ringPIP), let ringMCP = point(.ringMCP),
              let little = point(.littleTip), let littlePIP = point(.littlePIP), let littleMCP = point(.littleMCP) else {
            return nil
        }

        func normalized(_ value: VNRecognizedPoint) -> AICameraCore.NormalizedPoint {
            .init(x: Double(value.location.x), y: Double(value.location.y))
        }
        let landmarks: [HandJoint: AICameraCore.NormalizedPoint] = [
            .wrist: normalized(wrist), .thumbTip: normalized(thumb),
            .indexTip: normalized(index), .indexPIP: normalized(indexPIP), .indexMCP: normalized(indexMCP),
            .middleTip: normalized(middle), .middlePIP: normalized(middlePIP), .middleMCP: normalized(middleMCP),
            .ringTip: normalized(ring), .ringPIP: normalized(ringPIP), .ringMCP: normalized(ringMCP),
            .littleTip: normalized(little), .littlePIP: normalized(littlePIP), .littleMCP: normalized(littleMCP),
        ]
        guard let kind = HandGestureClassifier.classify(landmarks) else { return nil }
        let confidence = Double([
            wrist, thumb, index, indexPIP, indexMCP, middle, middlePIP, middleMCP,
            ring, ringPIP, ringMCP, little, littlePIP, littleMCP,
        ].map(\.confidence).min() ?? 0)
        var x = Double(index.location.x)
        if mirrored { x = 1 - x }
        let location = NormalizedPoint(x: x, y: 1 - Double(index.location.y))
        return GestureObservation(kind: kind, confidence: confidence, location: location)
    }
}
