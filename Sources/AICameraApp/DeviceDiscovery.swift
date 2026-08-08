import AVFoundation
import CoreAudio
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

enum DeviceDiscovery {
    static func videoInputs(excluding excludedID: String? = nil) -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
            .filter { $0.uniqueID != excludedID }
            .map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func audioInputs() -> [MediaDevice] {
        audioDevices()
            .filter {
                $0.id != AICameraAudioDevice.uid
                    && hasStreams(deviceID: $0.audioObjectID, scope: kAudioDevicePropertyScopeInput)
            }
            .map { MediaDevice(id: $0.id, name: $0.name) }
    }

    static func audioOutputs() -> [AudioOutputDevice] {
        audioDevices().filter { isDuplexVirtualAudioDevice($0.audioObjectID) }
    }

    static func isDuplexVirtualAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            && hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            && transportType(deviceID: deviceID) == kAudioDeviceTransportTypeVirtual
    }

    static func audioDeviceID(forUID uid: String, requiringScope scope: AudioObjectPropertyScope? = nil) -> AudioDeviceID? {
        guard let device = audioDevices().first(where: { $0.id == uid }) else { return nil }
        if let scope, !hasStreams(deviceID: device.audioObjectID, scope: scope) { return nil }
        return device.audioObjectID
    }

    private static func audioDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: id) else { return nil }
            return AudioOutputDevice(id: uid, name: name, audioObjectID: id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
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

    private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }
}
