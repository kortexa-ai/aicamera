import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOSurface

/// Pushes processed host frames into the output/sink stream of the camera extension.
/// The queue is intentionally bounded: `enqueue` returns `false` instead of adding latency.
final class VirtualCameraFeeder {
    struct Configuration: Equatable, Sendable {
        let width: Int32
        let height: Int32
        let framesPerSecond: Int32

        static let defaultHD = Configuration(width: 1280, height: 720, framesPerSecond: 30)
    }

    enum FeederError: LocalizedError {
        case alreadyStopped
        case cameraUnavailable
        case sinkStreamUnavailable
        case unsupportedConfiguration(Configuration)
        case propertyFailure(String, OSStatus)
        case streamStartFailed(OSStatus)
        case notRunning
        case invalidSampleBuffer
        case incompatiblePixelBuffer
        case pixelBufferAllocationFailed(CVReturn)
        case sampleBufferCreationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .alreadyStopped:
                return "The virtual camera feeder is already stopped"
            case .cameraUnavailable:
                return "The AI Camera virtual device is not available"
            case .sinkStreamUnavailable:
                return "The AI Camera feeder sink stream is not available"
            case let .unsupportedConfiguration(configuration):
                return "Unsupported virtual camera format \(configuration.width)x\(configuration.height) at \(configuration.framesPerSecond) fps"
            case let .propertyFailure(name, status):
                return "CoreMediaIO property \(name) failed with status \(status)"
            case let .streamStartFailed(status):
                return "Unable to start the virtual camera feeder stream (status \(status))"
            case .notRunning:
                return "The virtual camera feeder is not running"
            case .invalidSampleBuffer:
                return "The frame is not a video image sample buffer"
            case .incompatiblePixelBuffer:
                return "The frame must be BGRA and match the configured dimensions"
            case let .pixelBufferAllocationFailed(status):
                return "Unable to allocate an IOSurface-backed pixel buffer (status \(status))"
            case let .sampleBufferCreationFailed(status):
                return "Unable to create the feeder sample buffer (status \(status))"
            }
        }
    }

    private let lock = NSLock()
    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var allocationAttributes: CFDictionary?
    private var activeConfiguration: Configuration?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sinkQueue != nil
    }

    var configuration: Configuration? {
        lock.lock()
        defer { lock.unlock() }
        return activeConfiguration
    }

    deinit {
        _ = stop()
    }

    func start(configuration: Configuration = .defaultHD) throws {
        guard let sharedFormat = AICameraVirtualCamera.formats.first(where: {
            $0.width == configuration.width && $0.height == configuration.height
        }), AICameraVirtualCamera.supportedFrameRates.contains(configuration.framesPerSecond) else {
            throw FeederError.unsupportedConfiguration(configuration)
        }

        lock.lock()
        defer { lock.unlock() }
        if sinkQueue != nil {
            if activeConfiguration == configuration { return }
            let stopStatus = stopLocked()
            guard stopStatus == noErr else {
                throw FeederError.propertyFailure("CMIODeviceStopStream", stopStatus)
            }
        }

        guard let foundDevice = try Self.findDevice(withUID: AICameraVirtualCamera.deviceUID) else {
            throw FeederError.cameraUnavailable
        }
        guard let foundSink = try Self.findSinkStream(on: foundDevice) else {
            throw FeederError.sinkStreamUnavailable
        }

        let description = try Self.makeFormatDescription(for: sharedFormat)
        try Self.setFormatDescription(description, on: foundSink)
        try Self.setFrameRate(configuration.framesPerSecond, on: foundSink)
        let pool = try Self.makePixelBufferPool(for: sharedFormat)

        var copiedQueue: Unmanaged<CMSimpleQueue>?
        let queueStatus = CMIOStreamCopyBufferQueue(
            foundSink,
            virtualCameraQueueAltered,
            nil,
            &copiedQueue
        )
        guard queueStatus == noErr, let copiedQueue else {
            throw FeederError.propertyFailure("CMIOStreamCopyBufferQueue", queueStatus)
        }
        let queue = copiedQueue.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(foundDevice, foundSink)
        guard startStatus == noErr else {
            Self.unregisterQueueCallback(for: foundSink)
            throw FeederError.streamStartFailed(startStatus)
        }

        deviceID = foundDevice
        sinkStreamID = foundSink
        sinkQueue = queue
        formatDescription = description
        pixelBufferPool = pool
        allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        activeConfiguration = configuration

        do {
            // A source client can negotiate between the initial property write and sink start.
            // Reassert the feeder format once the extension has locked source changes.
            try Self.setFormatDescription(description, on: foundSink)
            try Self.setFrameRate(configuration.framesPerSecond, on: foundSink)
        } catch {
            let stopStatus = stopLocked()
            guard stopStatus == noErr else {
                throw FeederError.propertyFailure("CMIODeviceStopStream", stopStatus)
            }
            throw error
        }
    }

    /// Stops feeding without deactivating or uninstalling the system extension.
    @discardableResult
    func stop() -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return stopLocked()
    }

    /// Enqueues one processed video frame. Returns false when the single-frame queue is full.
    @discardableResult
    func enqueue(_ inputSampleBuffer: CMSampleBuffer) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let queue = sinkQueue,
              let configuration = activeConfiguration,
              let description = formatDescription,
              let pool = pixelBufferPool,
              let allocationAttributes else {
            throw FeederError.notRunning
        }
        guard CMSampleBufferIsValid(inputSampleBuffer),
              let inputPixelBuffer = CMSampleBufferGetImageBuffer(inputSampleBuffer) else {
            throw FeederError.invalidSampleBuffer
        }
        guard CVPixelBufferGetWidth(inputPixelBuffer) == Int(configuration.width),
              CVPixelBufferGetHeight(inputPixelBuffer) == Int(configuration.height),
              CVPixelBufferGetPixelFormatType(inputPixelBuffer) == AICameraVirtualCamera.pixelFormat else {
            throw FeederError.incompatiblePixelBuffer
        }

        // Never build a backlog. The extension advertises a queue size of one as well.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            return false
        }

        let outputPixelBuffer: CVPixelBuffer
        if CVPixelBufferGetIOSurface(inputPixelBuffer) != nil {
            outputPixelBuffer = inputPixelBuffer
        } else {
            var allocated: CVPixelBuffer?
            let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                allocationAttributes,
                &allocated
            )
            guard allocationStatus == kCVReturnSuccess, let allocated else {
                throw FeederError.pixelBufferAllocationFailed(allocationStatus)
            }
            try Self.copyBGRA(from: inputPixelBuffer, to: allocated)
            outputPixelBuffer = allocated
        }

        let inputPTS = CMSampleBufferGetPresentationTimeStamp(inputSampleBuffer)
        let presentationTime = inputPTS.isNumeric
            ? inputPTS
            : CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: .aicameraFrameDuration(rate: configuration.framesPerSecond),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var outputSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outputPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &outputSampleBuffer
        )
        guard sampleStatus == noErr, let outputSampleBuffer else {
            throw FeederError.sampleBufferCreationFailed(sampleStatus)
        }

        let token = Unmanaged.passRetained(outputSampleBuffer).toOpaque()
        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: token)
        guard enqueueStatus == noErr else {
            Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
            if enqueueStatus == kCMSimpleQueueError_QueueIsFull {
                return false
            }
            throw FeederError.propertyFailure("CMSimpleQueueEnqueue", enqueueStatus)
        }
        return true
    }

    private func stopLocked() -> OSStatus {
        guard let deviceID, let sinkStreamID else {
            clearStateLocked()
            return noErr
        }
        let status = CMIODeviceStopStream(deviceID, sinkStreamID)
        guard status == noErr else { return status }
        Self.unregisterQueueCallback(for: sinkStreamID)
        clearStateLocked()
        return noErr
    }

    private func clearStateLocked() {
        deviceID = nil
        sinkStreamID = nil
        sinkQueue = nil
        formatDescription = nil
        pixelBufferPool = nil
        allocationAttributes = nil
        activeConfiguration = nil
    }

    private static func findDevice(withUID expectedUID: String) throws -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            throw FeederError.propertyFailure("kCMIOHardwarePropertyDevices", sizeStatus)
        }

        var devices = [CMIODeviceID](
            repeating: CMIODeviceID(kCMIOObjectUnknown),
            count: Int(dataSize) / MemoryLayout<CMIODeviceID>.stride
        )
        var dataUsed: UInt32 = 0
        let readStatus = devices.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                bytes.baseAddress!
            )
        }
        guard readStatus == noErr else {
            throw FeederError.propertyFailure("kCMIOHardwarePropertyDevices", readStatus)
        }

        for device in devices {
            if try stringProperty(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID), objectID: device) == expectedUID {
                return device
            }
        }
        return nil
    }

    private static func findSinkStream(on deviceID: CMIODeviceID) throws -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            throw FeederError.propertyFailure("kCMIODevicePropertyStreams", sizeStatus)
        }

        var streams = [CMIOStreamID](
            repeating: CMIOStreamID(kCMIOObjectUnknown),
            count: Int(dataSize) / MemoryLayout<CMIOStreamID>.stride
        )
        var dataUsed: UInt32 = 0
        let readStatus = streams.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                bytes.baseAddress!
            )
        }
        guard readStatus == noErr else {
            throw FeederError.propertyFailure("kCMIODevicePropertyStreams", readStatus)
        }

        for stream in streams {
            var directionAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var direction: UInt32 = UInt32.max
            let directionSize = UInt32(MemoryLayout<UInt32>.stride)
            var directionUsed: UInt32 = 0
            let directionStatus = CMIOObjectGetPropertyData(
                stream,
                &directionAddress,
                0,
                nil,
                directionSize,
                &directionUsed,
                &direction
            )
            guard directionStatus == noErr else { continue }
            // In the legacy CMIO API, direction 0 is a device output: the host
            // writes to this queue, which maps to the extension's sink stream.
            if direction == 0 {
                return stream
            }
        }
        return nil
    }

    private static func stringProperty(
        _ selector: CMIOObjectPropertySelector,
        objectID: CMIOObjectID
    ) throws -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else { return nil }
        var value: Unmanaged<CFString>?
        let dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            &value
        )
        guard status == noErr else {
            throw FeederError.propertyFailure("CMIO string property", status)
        }
        return value?.takeRetainedValue() as String?
    }

    private static func makeFormatDescription(
        for format: AICameraVirtualCameraFormat
    ) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: AICameraVirtualCamera.pixelFormat,
            width: format.width,
            height: format.height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FeederError.propertyFailure("CMVideoFormatDescriptionCreate", status)
        }
        return description
    }

    private static func setFormatDescription(
        _ description: CMVideoFormatDescription,
        on streamID: CMIOStreamID
    ) throws {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value = Unmanaged.passUnretained(description)
        let status = CMIOObjectSetPropertyData(
            streamID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Unmanaged<CMFormatDescription>>.stride),
            &value
        )
        guard status == noErr else {
            throw FeederError.propertyFailure("kCMIOStreamPropertyFormatDescription", status)
        }
    }

    private static func setFrameRate(_ frameRate: Int32, on streamID: CMIOStreamID) throws {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value = Float64(frameRate)
        let status = CMIOObjectSetPropertyData(
            streamID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.stride),
            &value
        )
        guard status == noErr else {
            throw FeederError.propertyFailure("kCMIOStreamPropertyFrameRate", status)
        }
    }

    private static func makePixelBufferPool(
        for format: AICameraVirtualCameraFormat
    ) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(format.width),
            kCVPixelBufferHeightKey: Int(format.height),
            kCVPixelBufferPixelFormatTypeKey: AICameraVirtualCamera.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw FeederError.pixelBufferAllocationFailed(status)
        }
        return pool
    }

    private static func copyBGRA(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw FeederError.incompatiblePixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw FeederError.incompatiblePixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            throw FeederError.incompatiblePixelBuffer
        }
        let rows = CVPixelBufferGetHeight(source)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let copyBytes = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0..<rows {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                copyBytes
            )
        }
    }

    private static func unregisterQueueCallback(for streamID: CMIOStreamID) {
        var ignoredQueue: Unmanaged<CMSimpleQueue>?
        if CMIOStreamCopyBufferQueue(streamID, nil, nil, &ignoredQueue) == noErr {
            ignoredQueue?.release()
        }
    }

}

/// CoreMediaIO requires a queue-altered callback for a sink queue. After a successful
/// enqueue, CMIO owns and disposes the retained sample on consumption or stream stop; the
/// notification token is borrowed and must not be released here.
private let virtualCameraQueueAltered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
