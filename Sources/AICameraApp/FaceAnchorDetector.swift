import AICameraCore
import CoreVideo
import Foundation
import Vision

/// Confined to a separate serial analysis queue, at most one request in flight. The caller
/// admits frames only while a requested face effect is active; no landmarks leave this Mac.
final class FaceAnchorDetector {
    func detect(in buffer: CVPixelBuffer, output: CGSize, mirrored: Bool) -> FaceAnchor? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        do {
            try handler.perform([request])
            let faces = (request.results ?? []).filter { $0.confidence >= 0.65 }
            guard faces.count == 1, let face = faces.first,
                  let left = eyeCenter(face.landmarks?.leftEye, in: face.boundingBox),
                  let right = eyeCenter(face.landmarks?.rightEye, in: face.boundingBox) else { return nil }
            let box = face.boundingBox
            return FaceAnchorGeometry.project(
                visionBox: .init(x: box.minX, y: box.minY, width: box.width, height: box.height),
                visionLeftEye: left, visionRightEye: right,
                source: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                output: output, mirrored: mirrored
            )
        } catch { return nil }
    }
    private func eyeCenter(_ region: VNFaceLandmarkRegion2D?, in box: CGRect) -> AICameraCore.NormalizedPoint? {
        guard let region, (1...32).contains(region.pointCount) else { return nil }
        let points = region.normalizedPoints
        let x = points.reduce(CGFloat.zero) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(CGFloat.zero) { $0 + $1.y } / CGFloat(points.count)
        return .init(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }
}
