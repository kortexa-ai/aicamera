import CoreMedia
import CoreVideo
import Foundation

/// Produces a cheap animated frame when the host feeder is not connected.
/// This object is confined to the device source's media queue.
final class PlaceholderFrameGenerator {
    private let format: AICameraVirtualCameraFormat
    private let formatDescription: CMVideoFormatDescription
    private let pool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary
    private var rowPixels: [UInt32]
    private var frameNumber: UInt64 = 0

    init?(
        format: AICameraVirtualCameraFormat,
        formatDescription: CMVideoFormatDescription
    ) {
        self.format = format
        self.formatDescription = formatDescription

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(format.width),
            kCVPixelBufferHeightKey: Int(format.height),
            kCVPixelBufferPixelFormatTypeKey: AICameraVirtualCamera.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
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

        let colors: [UInt32] = [
            0xFF202020, 0xFF244A7C, 0xFF287A52, 0xFF377E84,
            0xFF754275, 0xFF7A5533, 0xFF8A8A8A, 0xFF303030,
        ]
        var generatedRow = [UInt32](repeating: colors[0], count: Int(format.width))
        for x in generatedRow.indices {
            generatedRow[x] = colors[min(colors.count - 1, x * colors.count / generatedRow.count)]
        }
        rowPixels = generatedRow
    }

    func makeSampleBuffer(
        presentationTimeStamp: CMTime,
        frameDuration: CMTime
    ) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            allocationAttributes,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        draw(into: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        frameNumber &+= 1
        return sampleBuffer
    }

    private func draw(into pixelBuffer: CVPixelBuffer) {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = Int(format.width)
        let height = Int(format.height)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let visibleRowBytes = width * MemoryLayout<UInt32>.stride

        rowPixels.withUnsafeBytes { row in
            guard let source = row.baseAddress else { return }
            for y in 0..<height {
                let destination = baseAddress.advanced(by: y * bytesPerRow)
                memcpy(destination, source, visibleRowBytes)
                if bytesPerRow > visibleRowBytes {
                    memset(destination.advanced(by: visibleRowBytes), 0, bytesPerRow - visibleRowBytes)
                }
            }
        }

        // An animated white scan line and binary blocks make a frozen stream obvious.
        let stripeHeight = max(3, height / 120)
        let stripeY = Int(frameNumber % UInt64(max(1, height - stripeHeight)))
        for y in stripeY..<(stripeY + stripeHeight) {
            memset(baseAddress.advanced(by: y * bytesPerRow), 0xFF, visibleRowBytes)
        }

        let block = max(4, min(width, height) / 40)
        let blockY = min(height - block, stripeHeight * 2)
        for bit in 0..<16 where (frameNumber & (1 << bit)) != 0 {
            let blockX = (bit + 1) * (block + 2)
            guard blockX + block <= width else { break }
            for y in blockY..<(blockY + block) {
                let pixel = baseAddress
                    .advanced(by: y * bytesPerRow + blockX * MemoryLayout<UInt32>.stride)
                    .assumingMemoryBound(to: UInt32.self)
                for x in 0..<block {
                    pixel[x] = 0xFFFFFFFF
                }
            }
        }
    }
}
