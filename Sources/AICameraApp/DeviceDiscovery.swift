import AICameraCore
import AVFoundation
import CoreAudio
import CoreMediaIO
import Foundation

struct MediaDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let audioObjectID: AudioDeviceID
}

enum DefaultInputFallbackReason: Equatable {
    case ineligibleDefault
    case incompatibleVideoFrameRate
}

struct DefaultInputFallback: Equatable {
    let excludedDefault: MediaDevice
    let isOwnVirtualDevice: Bool
    let reason: DefaultInputFallbackReason
}

struct VideoInputResolution {
    let device: AVCaptureDevice?
    let fallback: DefaultInputFallback?
}

struct AudioInputResolution {
    let deviceID: AudioDeviceID?
    let device: MediaDevice?
    let fallback: DefaultInputFallback?
}

private struct DefaultVideoInput {
    let mediaDevice: MediaDevice
    let captureDevice: AVCaptureDevice?
}

enum DeviceDiscovery {
    static func resolveVideoInput(
        requestedID: String?,
        excluding excludedID: String,
        requestedFPS: Double
    ) -> VideoInputResolution {
        let discovered = videoCaptureDevices()
        let hardware = discovered.filter {
            isEligibleVideoInput($0, excluding: excludedID)
        }.sorted(by: videoDeviceIsOrderedBefore)
        if let requestedID {
            return VideoInputResolution(
                device: hardware.first(where: {
                    $0.uniqueID == requestedID && supports($0, requestedFPS: requestedFPS)
                }),
                fallback: nil
            )
        }

        let systemDefault = defaultVideoInput(from: discovered)
        let fallback = systemDefault.flatMap { input -> DefaultInputFallback? in
            guard let device = input.captureDevice,
                  isEligibleVideoInput(device, excluding: excludedID) else {
                return DefaultInputFallback(
                    excludedDefault: input.mediaDevice,
                    isOwnVirtualDevice: input.mediaDevice.id == excludedID,
                    reason: .ineligibleDefault
                )
            }
            guard supports(device, requestedFPS: requestedFPS) else {
                return DefaultInputFallback(
                    excludedDefault: input.mediaDevice,
                    isOwnVirtualDevice: false,
                    reason: .incompatibleVideoFrameRate
                )
            }
            return nil
        }
        let compatible = hardware.filter { supports($0, requestedFPS: requestedFPS) }
        let selectedID = PhysicalInputPolicy.resolvedDefault(
            preferredID: systemDefault?.mediaDevice.id,
            eligibleIDs: compatible.map(\.uniqueID)
        )
        let selected = selectedID.flatMap { id in
            compatible.first(where: { $0.uniqueID == id })
        }
        return VideoInputResolution(device: selected, fallback: fallback)
    }

    static func videoDeviceIsAvailable(withUID uid: String) -> Bool {
        videoCaptureDevices().contains(where: { $0.uniqueID == uid })
    }

    static func videoInputs(excluding excludedID: String? = nil) -> [MediaDevice] {
        videoCaptureDevices()
            .filter { device in
                guard let excludedID else {
                    return isEligibleVideoInput(device, excluding: "")
                }
                return isEligibleVideoInput(device, excluding: excludedID)
            }
            .map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted(by: mediaDeviceIsOrderedBefore)
    }

    static func audioInputs() -> [MediaDevice] {
        eligibleAudioInputs(excludingUID: AICameraAudioDevice.uid)
            .map { MediaDevice(id: $0.id, name: $0.name) }
    }

    static func audioOutputs() -> [AudioOutputDevice] {
        audioDevices().filter { isDuplexVirtualAudioDevice($0.audioObjectID) }
    }

    static func resolveDefaultAudioInput(excludingUID excludedUID: String) -> AudioInputResolution {
        let devices = audioDevices()
        let hardware = devices.filter {
            isEligibleAudioInput($0, excludingUID: excludedUID)
        }
        let defaultID = defaultAudioInputDeviceID()
        let systemDefault = defaultID.flatMap { id in
            devices.first(where: { $0.audioObjectID == id })
        }
        let fallback = systemDefault.flatMap { device -> DefaultInputFallback? in
            guard !isEligibleAudioInput(device, excludingUID: excludedUID) else { return nil }
            return DefaultInputFallback(
                excludedDefault: MediaDevice(id: device.id, name: device.name),
                isOwnVirtualDevice: device.id == excludedUID,
                reason: .ineligibleDefault
            )
        }
        let selectedID = PhysicalInputPolicy.resolvedDefault(
            preferredID: systemDefault?.id,
            eligibleIDs: hardware.map(\.id)
        )
        let selected = selectedID.flatMap { id in
            hardware.first(where: { $0.id == id })
        }
        return AudioInputResolution(
            deviceID: selected?.audioObjectID,
            device: selected.map { MediaDevice(id: $0.id, name: $0.name) },
            fallback: fallback
        )
    }

    static func physicalAudioInputDeviceID(forUID uid: String) -> AudioDeviceID? {
        eligibleAudioInputs(excludingUID: AICameraAudioDevice.uid)
            .first(where: { $0.id == uid })?
            .audioObjectID
    }

    static func audioCaptureDevice(forUID uid: String) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.first(where: { $0.uniqueID == uid })
    }

    static func isDuplexVirtualAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            && hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            && transportType(deviceID: deviceID) == kAudioDeviceTransportTypeVirtual
    }

    static func aiCameraCameraDemandSnapshot() -> AICameraCameraDemandSnapshot? {
        guard let deviceID = cmioDeviceID(forUID: AICameraVirtualCamera.deviceUID) else {
            return nil
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: AICameraMediaDemandState.cameraDemandSelector,
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &address) else { return nil }

        // The CoreMediaIO custom NSData bridge reports and copies raw bytes. Retry once if
        // a concurrent demand update changes the encoded payload size between the two calls.
        for _ in 0..<2 {
            var size: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &size
            ) == noErr,
            size > 0,
            size <= UInt32(AICameraMediaDemandState.maximumCameraSnapshotBytes) else {
                return nil
            }
            var data = Data(count: Int(size))
            var used: UInt32 = 0
            let status = data.withUnsafeMutableBytes { bytes in
                CMIOObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    size,
                    &used,
                    bytes.baseAddress!
                )
            }
            guard status == noErr, used == size else { continue }
            return AICameraMediaDemandState.decodeCameraSnapshot(data)
        }
        return nil
    }

    static func aiCameraAudioConsumerCount() -> Int {
        guard let deviceID = audioDeviceID(forUID: AICameraAudioDevice.uid) else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x61696363), // 'aicc'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr,
        size == UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size),
        let propertyList = value?.takeRetainedValue(),
        CFGetTypeID(propertyList) == CFNumberGetTypeID(),
        let count = propertyList as? NSNumber,
        count.intValue >= 0 else { return 0 }
        return count.intValue
    }

    static func audioDeviceID(
        forUID uid: String,
        requiringScope scope: AudioObjectPropertyScope? = nil
    ) -> AudioDeviceID? {
        guard let device = audioDevices().first(where: { $0.id == uid }) else { return nil }
        if let scope, !hasStreams(deviceID: device.audioObjectID, scope: scope) { return nil }
        return device.audioObjectID
    }

    private static func defaultVideoInput(
        from discovered: [AVCaptureDevice]
    ) -> DefaultVideoInput? {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyDefaultInputDevice),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var objectID = CMIOObjectID(kCMIOObjectUnknown)
        let size = UInt32(MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        if CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &used,
            &objectID
        ) == noErr,
           objectID != CMIOObjectID(kCMIOObjectUnknown),
           let uid = cmioStringProperty(
               UInt32(kCMIODevicePropertyDeviceUID),
               objectID: objectID
           ),
           let name = cmioStringProperty(
               UInt32(kCMIOObjectPropertyName),
               objectID: objectID
           ) {
            return DefaultVideoInput(
                mediaDevice: MediaDevice(id: uid, name: name),
                captureDevice: discovered.first(where: { $0.uniqueID == uid })
            )
        }

        guard let preferred = AVCaptureDevice.default(for: .video)
            ?? AVCaptureDevice.systemPreferredCamera else { return nil }
        return DefaultVideoInput(
            mediaDevice: MediaDevice(
                id: preferred.uniqueID,
                name: preferred.localizedName
            ),
            captureDevice: preferred
        )
    }

    private static func cmioDeviceID(forUID uid: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyDeviceForUID),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var input: CFString = uid as CFString
        var output = CMIOObjectID(kCMIOObjectUnknown)
        var used: UInt32 = 0
        let status = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(mutating: inputPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(outputPointer),
                    mOutputDataSize: UInt32(MemoryLayout<CMIOObjectID>.size)
                )
                return CMIOObjectGetPropertyData(
                    CMIOObjectID(kCMIOObjectSystemObject),
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioValueTranslation>.size),
                    &used,
                    &translation
                )
            }
        }
        guard status == noErr,
              used == UInt32(MemoryLayout<AudioValueTranslation>.size),
              output != CMIOObjectID(kCMIOObjectUnknown) else { return nil }
        return output
    }

    private static func cmioStringProperty(
        _ selector: CMIOObjectPropertySelector,
        objectID: CMIOObjectID
    ) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            size,
            &used,
            &value
        ) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func videoCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func isEligibleVideoInput(
        _ device: AVCaptureDevice,
        excluding excludedID: String
    ) -> Bool {
        device.uniqueID != excludedID
            && PhysicalInputPolicy.isEligible(
                transportType: UInt32(bitPattern: device.transportType),
                isContinuityDevice: device.isContinuityCamera
            )
    }

    private static func videoDeviceIsOrderedBefore(
        _ lhs: AVCaptureDevice,
        _ rhs: AVCaptureDevice
    ) -> Bool {
        let nameOrder = lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName)
        return nameOrder == .orderedSame
            ? lhs.uniqueID < rhs.uniqueID
            : nameOrder == .orderedAscending
    }

    private static func mediaDeviceIsOrderedBefore(_ lhs: MediaDevice, _ rhs: MediaDevice) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
    }

    private static func audioDeviceIsOrderedBefore(
        _ lhs: AudioOutputDevice,
        _ rhs: AudioOutputDevice
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
    }

    private static func supports(_ device: AVCaptureDevice, requestedFPS: Double) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { range in
                NominalFrameRateMatcher.match(
                    requestedFPS: requestedFPS,
                    minimumFPS: range.minFrameRate,
                    maximumFPS: range.maxFrameRate
                ) != nil
            }
        }
    }

    private static func defaultAudioInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultID
        ) == noErr, defaultID != kAudioObjectUnknown else { return nil }
        return defaultID
    }

    private static func eligibleAudioInputs(excludingUID excludedUID: String) -> [AudioOutputDevice] {
        audioDevices().filter { isEligibleAudioInput($0, excludingUID: excludedUID) }
    }

    private static func isEligibleAudioInput(
        _ device: AudioOutputDevice,
        excludingUID excludedUID: String
    ) -> Bool {
        guard device.id != excludedUID,
              hasStreams(deviceID: device.audioObjectID, scope: kAudioDevicePropertyScopeInput),
              let transport = transportType(deviceID: device.audioObjectID) else { return false }
        return PhysicalInputPolicy.isEligible(transportType: transport)
    }

    private static func audioDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: id) else { return nil }
            return AudioOutputDevice(id: uid, name: name, audioObjectID: id)
        }.sorted(by: audioDeviceIsOrderedBefore)
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private static func hasStreams(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size > 0
    }
}
