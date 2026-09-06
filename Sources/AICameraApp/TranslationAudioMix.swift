import AVFoundation
import AudioToolbox

/// The output mix is limited after microphone/speech gains. The clean capture never enters this path.
enum TranslationAudioMix {
    static func installLimiter(in engine: AVAudioEngine, format: AVAudioFormat) -> AVAudioUnitEffect {
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        return limiter
    }
}

/// Twenty-millisecond gain ramps avoid clicks; mutate only an outgoing copy, never the ASR input.
struct TranslationDucking {
    private(set) var gain: Float = 1
    mutating func outgoing(_ input: AVAudioPCMBuffer, speaking: Bool) -> AVAudioPCMBuffer? {
        guard let source = input.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = input.frameLength
        let target: Float = speaking ? 0.25 : 1
        let step = Float(0.75 / (input.format.sampleRate * 0.02))
        for i in 0..<Int(input.frameLength) {
            gain = gain < target ? min(target, gain + step) : max(target, gain - step)
            for channel in 0..<Int(input.format.channelCount) { destination[channel][i] = source[channel][i] * gain }
        }
        return copy
    }
}
