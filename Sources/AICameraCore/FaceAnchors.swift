import CoreGraphics
import Foundation

/// A small anonymous 2D anchor in the overlay canvas: origin top-left, coordinates normalized.
/// It describes geometry, not identity, expression, attention, or a dense 3D face mesh.
public struct FaceAnchor: Codable, Equatable, Sendable {
    public let box: NormalizedRect
    public let center: NormalizedPoint
    public let top: NormalizedPoint
    public let leftEye: NormalizedPoint
    public let rightEye: NormalizedPoint
    public let roll: Double
}

public enum FaceAnchorGeometry {
    public static func isValid(_ anchor: FaceAnchor) -> Bool {
        let box = anchor.box
        guard [box.x, box.y, box.width, box.height, anchor.roll].allSatisfy(\.isFinite),
              box.x >= 0, box.y >= 0, box.width > 0, box.height > 0,
              box.x + box.width <= 1, box.y + box.height <= 1, abs(anchor.roll) <= .pi / 2 else { return false }
        let points = [anchor.center, anchor.top, anchor.leftEye, anchor.rightEye]
        return points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (-0.5...1.5).contains($0.x) && (-0.5...1.5).contains($0.y) }
    }
    /// Match the camera compositor's aspect-fill crop/mirror, then invert the overlay canvas's
    /// aspect-fill crop. This keeps anchors aligned even with a 4:3 camera and 16:9 WebGL canvas.
    public static func project(visionBox: NormalizedRect, visionLeftEye: NormalizedPoint,
                               visionRightEye: NormalizedPoint, source: CGSize, output: CGSize,
                               mirrored: Bool) -> FaceAnchor? {
        guard [source.width, source.height, output.width, output.height].allSatisfy({ $0.isFinite && $0 > 0 }),
              [visionBox.x, visionBox.y, visionBox.width, visionBox.height].allSatisfy(\.isFinite),
              visionBox.x >= 0, visionBox.y >= 0, visionBox.width > 0, visionBox.height > 0,
              visionBox.x + visionBox.width <= 1, visionBox.y + visionBox.height <= 1 else { return nil }
        let scale = max(output.width / source.width, output.height / source.height)
        let cropX = (source.width * scale - output.width) / 2
        let cropY = (source.height * scale - output.height) / 2
        func cameraPoint(_ point: NormalizedPoint) -> NormalizedPoint {
            var x = (point.x * source.width * scale - cropX) / output.width
            if mirrored { x = 1 - x }
            return .init(x: x, y: 1 - (point.y * source.height * scale - cropY) / output.height)
        }
        let a = cameraPoint(.init(x: visionBox.x, y: visionBox.y))
        let b = cameraPoint(.init(x: visionBox.x + visionBox.width, y: visionBox.y + visionBox.height))
        let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
        // Partial/off-screen faces are deliberately omitted in this first effect mode.
        guard left >= 0, right <= 1, top >= 0, bottom <= 1,
              right - left >= 0.04, bottom - top >= 0.06 else { return nil }
        let canvas = CGSize(width: OverlayFramePolicy.width, height: OverlayFramePolicy.height)
        let canvasScale = max(output.width / canvas.width, output.height / canvas.height)
        func canvasPoint(_ point: NormalizedPoint) -> NormalizedPoint {
            .init(x: (point.x * output.width + (canvas.width * canvasScale - output.width) / 2) / (canvas.width * canvasScale),
                  y: (point.y * output.height + (canvas.height * canvasScale - output.height) / 2) / (canvas.height * canvasScale))
        }
        let upper = canvasPoint(.init(x: left, y: top)), lower = canvasPoint(.init(x: right, y: bottom))
        var eyes = [canvasPoint(cameraPoint(visionLeftEye)), canvasPoint(cameraPoint(visionRightEye))]
        guard eyes.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (upper.x...lower.x).contains($0.x) && (upper.y...lower.y).contains($0.y) }) else { return nil }
        eyes.sort { $0.x < $1.x }
        let dx = eyes[1].x - eyes[0].x, dy = eyes[1].y - eyes[0].y
        guard dx > 0.005 else { return nil }
        return .init(box: .init(x: upper.x, y: upper.y, width: lower.x - upper.x, height: lower.y - upper.y),
                     center: canvasPoint(.init(x: (left + right) / 2, y: (top + bottom) / 2)),
                     top: canvasPoint(.init(x: (left + right) / 2, y: top - (bottom - top) * 0.2)),
                     leftEye: eyes[0], rightEye: eyes[1],
                     roll: atan2(-dy * canvas.height, dx * canvas.width))
    }
}

/// One latest value, one effect generation, and no I/O on the capture path. A new tracking ID
/// after loss prevents pixels rendered for a retired face position from returning on reacquisition.
public final class FaceAnchorState: @unchecked Sendable {
    public static let maximumAge: TimeInterval = 0.35
    public struct Sample: Sendable {
        public let generation: UUID
        public let trackingID: UUID
        public let anchor: FaceAnchor
        public let capturedAt: TimeInterval

        public func json(at uptime: TimeInterval) -> String? {
            struct Payload: Encodable {
                let trackingID: String
                let ageSeconds: Double
                let box: NormalizedRect
                let center: NormalizedPoint
                let top: NormalizedPoint
                let leftEye: NormalizedPoint
                let rightEye: NormalizedPoint
                let roll: Double
            }
            guard uptime.isFinite, (0...FaceAnchorState.maximumAge).contains(uptime - capturedAt),
                  let data = try? JSONEncoder().encode(Payload(trackingID: trackingID.uuidString,
                     ageSeconds: uptime - capturedAt, box: anchor.box, center: anchor.center, top: anchor.top,
                     leftEye: anchor.leftEye, rightEye: anchor.rightEye, roll: anchor.roll)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    private let lock = NSLock()
    private var generation: UUID?
    private var sample: Sample?
    private var latestCapturedAt = -Double.infinity
    // Shared across camera-controller/effect replacement. Keep a retired request's permit until
    // its worker returns, so repeated restarts cannot accumulate native Vision work or buffers.
    private var analysisID: UUID?

    public init() {}
    public var requestedGeneration: UUID? { lock.lock(); defer { lock.unlock() }; return generation }
    public func beginAnalysis(generation expected: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected, analysisID == nil else { return nil }
        let id = UUID(); analysisID = id; return id
    }
    public func endAnalysis(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if analysisID == id { analysisID = nil }
    }
    @discardableResult public func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); generation = value; sample = nil; latestCapturedAt = -.infinity
        return value
    }
    public func end(generation expected: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return }
        generation = nil; sample = nil; latestCapturedAt = -.infinity
    }
    @discardableResult public func apply(_ anchor: FaceAnchor?, generation expected: UUID, capturedAt: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected, capturedAt.isFinite, capturedAt >= latestCapturedAt else { return false }
        latestCapturedAt = capturedAt
        guard let anchor else { sample = nil; return true }
        guard FaceAnchorGeometry.isValid(anchor) else { sample = nil; return false }
        let sameTrack = sample.map { capturedAt - $0.capturedAt <= Self.maximumAge } ?? false
        sample = .init(generation: expected, trackingID: sameTrack ? sample!.trackingID : UUID(), anchor: anchor, capturedAt: capturedAt)
        return true
    }
    public func fresh(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Sample? {
        lock.lock(); defer { lock.unlock() }
        guard let sample, sample.generation == generation, uptime.isFinite,
              (0...Self.maximumAge).contains(uptime - sample.capturedAt) else { return nil }
        return sample
    }
}
