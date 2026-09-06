import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A second output for agent replies when the primary graph writes to the virtual microphone.
/// Its caller owns the bounded buffer count and waits for both outputs before rearming input.
final class SpeechOutputMonitor {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()

    init(format: AVAudioFormat, gain: Float, engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = gain
    }

    func start(deviceID: AudioDeviceID? = nil) throws {
        if var deviceID {
            guard let unit = engine.outputNode.audioUnit else { throw error("Local reply output is unavailable.") }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw error("The local reply output device could not be selected.") }
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool {
        guard engine.isRunning else { return false }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        if !player.isPlaying { player.play() }
        return true
    }

    func silence() { engine.mainMixerNode.outputVolume = 0 }
    func reset() { player.stop() }
    func stop() { player.stop(); engine.stop() }

    private func error(_ message: String) -> NSError {
        NSError(domain: "AICamera.SpeechMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
