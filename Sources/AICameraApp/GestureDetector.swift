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
              let index = point(.indexTip), let indexPIP = point(.indexPIP),
              let middle = point(.middleTip), let middlePIP = point(.middlePIP),
              let ring = point(.ringTip), let ringPIP = point(.ringPIP),
              let little = point(.littleTip), let littlePIP = point(.littlePIP) else { return nil }

        func distance(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> Double {
            hypot(Double(a.location.x - b.location.x), Double(a.location.y - b.location.y))
        }
        let indexUp = index.location.y > indexPIP.location.y + 0.025
        let middleUp = middle.location.y > middlePIP.location.y + 0.025
        let ringUp = ring.location.y > ringPIP.location.y + 0.02
        let littleUp = little.location.y > littlePIP.location.y + 0.02

        let kind: GestureKind
        if distance(thumb, index) < 0.075 {
            kind = .pinch
        } else if indexUp && middleUp && !ringUp && !littleUp {
            kind = .victory
        } else if indexUp && !middleUp && !ringUp && !littleUp {
            kind = .pointing
        } else if indexUp && middleUp && ringUp && littleUp {
            kind = .openPalm
        } else if !indexUp && !middleUp && !ringUp && !littleUp,
                  [index, middle, ring, little].allSatisfy({ distance($0, wrist) < 0.42 }) {
            kind = .closedFist
        } else {
            kind = .unknown
        }
        let confidence = Double([thumb, index, middle, ring, little].map(\.confidence).min() ?? 0)
        var x = Double(index.location.x)
        if mirrored { x = 1 - x }
        let location = NormalizedPoint(x: x, y: 1 - Double(index.location.y))
        return GestureObservation(kind: kind, confidence: confidence, location: location)
    }
}
