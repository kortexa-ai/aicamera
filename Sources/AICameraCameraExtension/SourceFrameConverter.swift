import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// Converts BGRA feeder and placeholder frames into one published 420v source format, scaling
/// and cropping to that format's dimensions. Confined to the device source's media queue.
final class SourceFrameConverter {
    let format: AICameraVirtualCameraFormat

    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary
    private var formatDescription: CMVideoFormatDescription?
    private let logger = Logger(subsystem: "ai.kortexa.aicamera.camera-extension", category: "converter")

    init?(format: AICameraVirtualCameraFormat) {
        self.format = format

        var createdSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &createdSession
        ) == noErr, let createdSession else {
            return nil
        }
        // Fill the destination and crop the source when aspect ratios differ, like a sensor crop.
        VTSessionSetProperty(createdSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        session = createdSession

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(format.width),
            kCVPixelBufferHeightKey: Int(format.height),
            kCVPixelBufferPixelFormatTypeKey: AICameraVirtualCamera.sourcePixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var createdPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &createdPool
        ) == kCVReturnSuccess, let createdPool else {
            return nil
        }
        pool = createdPool
        allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    }

    func makeSampleBuffer(
        from source: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        frameDuration: CMTime
    ) -> CMSampleBuffer? {
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            allocationAttributes,
            &destination
        ) == kCVReturnSuccess, let destination else {
            return nil
        }
        let transferStatus = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard transferStatus == noErr else {
            logger.error("Pixel transfer to 420v failed: \(transferStatus, privacy: .public)")
            return nil
        }

        // Describe the buffers actually produced, so the description and its attachments agree.
        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: destination) {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: destination,
                formatDescriptionOut: &description
            ) == noErr, let description else {
                return nil
            }
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destination,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
