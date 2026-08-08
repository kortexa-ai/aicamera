import CoreMedia
import CoreVideo
import Foundation

/// Stable identifiers and media formats used by both the host and camera extension.
enum AICameraVirtualCamera {
    static let hostBundleIdentifier = "ai.kortexa.aicamera"
    static let extensionBundleIdentifier = "ai.kortexa.aicamera.camera-extension"
    static let localizedName = "AI Camera"
    static let manufacturer = "Kortexa"
    static let model = "AI Camera Virtual Camera"

    // These IDs are part of the virtual device's persistent identity. Do not regenerate them.
    static let deviceID = UUID(uuidString: "38A6609A-FA9E-44FE-B667-4536B8491009")!
    static let sourceStreamID = UUID(uuidString: "4B37D278-B704-4F95-B975-B93759859C54")!
    static let sinkStreamID = UUID(uuidString: "021E8093-F62D-42BD-AC47-D05A08D76FEB")!
    static let deviceUID = deviceID.uuidString

    static let pixelFormat: OSType = kCVPixelFormatType_32BGRA
    static let supportedFrameRates: [Int32] = [15, 30, 60]
    static let formats: [AICameraVirtualCameraFormat] = [
        .init(width: 640, height: 480),
        .init(width: 1280, height: 720),
        .init(width: 1920, height: 1080),
    ]
    static let defaultFormatIndex = 1
    static let defaultFrameRate: Int32 = 30
}

struct AICameraVirtualCameraFormat: Equatable, Sendable {
    let width: Int32
    let height: Int32

    var dimensions: CMVideoDimensions {
        CMVideoDimensions(width: width, height: height)
    }

    func supports(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(pixelBuffer) == Int(width)
            && CVPixelBufferGetHeight(pixelBuffer) == Int(height)
            && CVPixelBufferGetPixelFormatType(pixelBuffer) == AICameraVirtualCamera.pixelFormat
    }
}

extension CMTime {
    static func aicameraFrameDuration(rate: Int32) -> CMTime {
        CMTime(value: 1, timescale: rate)
    }
}
