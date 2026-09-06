import AVFoundation
import CoreAudio
import Foundation

// Exercise the actual local reply monitor using offline AVAudioEngine rendering. No audio devices.
private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func finish() { lock.lock(); value = true; lock.unlock() }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
@main
private struct SpeechMonitorValidation {
    static func main() async throws {
        for rate in [44_100.0, 48_000.0] { try await validate(rate: rate) }
        try await liveSilentDrain()
        print("Passed local reply monitor: 44.1/48 kHz offline PCM/gain, mute/reset silence, stopped-output denial; silent hardware playback drains")
    }
    private static func validate(rate: Double) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let engine = AVAudioEngine()
        let monitor = SpeechOutputMonitor(format: format, gain: 0.5, engine: engine)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try monitor.start()
        defer { monitor.stop() }
        let fixture = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)!
        fixture.frameLength = fixture.frameCapacity
        for channel in 0..<2 {
            for index in 0..<Int(fixture.frameLength) { fixture.floatChannelData![channel][index] = 0.25 }
        }
        let completed = Completion()
        try require(monitor.schedule(fixture, completion: { completed.finish() }), "Monitor rejected valid PCM")
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var peak: Float = 0
        for _ in 0..<8 { peak = max(peak, try render(engine, output)) }
        try require(peak > 0.1 && peak < 0.14, "Local reply PCM/gain was not preserved")
        // Offline rendering has no hardware playback clock; dataPlayedBack is checked below
        // with a silent synthetic buffer on the current physical output instead.
        try require(monitor.schedule(fixture, completion: {}), "Second reply rejected")
        monitor.silence()
        monitor.reset()
        _ = try render(engine, output)
        try require(try render(engine, output) == 0, "Mute/reset left audible PCM")
        monitor.stop()
        try require(!monitor.schedule(fixture, completion: {}), "Stopped monitor accepted late PCM")
    }
    private static func liveSilentDrain() async throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
                    && device != kAudioObjectUnknown, "No default output for silent drain test")
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        try require(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
                    "Output transport unavailable")
        let physical = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                        kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeDisplayPort,
                        kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeBluetooth,
                        kAudioDeviceTransportTypeBluetoothLE]
        try require(physical.contains(transport), "Silent drain test requires a physical default output")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let monitor = SpeechOutputMonitor(format: format, gain: 1)
        try monitor.start(deviceID: device)
        defer { monitor.stop() }
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        silence.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 { silence.floatChannelData![channel][index] = 0 }
        }
        let completed = Completion()
        try require(monitor.schedule(silence, completion: { completed.finish() }), "Silent playback rejected")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !completed.finished {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Silent hardware playback did not drain")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func render(_ engine: AVAudioEngine, _ output: AVAudioPCMBuffer) throws -> Float {
        let status = try engine.renderOffline(512, to: output)
        try require(status == .success, "Offline render failed")
        var peak: Float = 0
        for channel in 0..<Int(output.format.channelCount) {
            for index in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![channel][index])) }
        }
        return peak
    }
}
