// Synthetic memory-only PCM checks. No device, network, Keychain, or audio file is opened.
import AVFoundation
import Foundation

private enum CheckFailure: Error { case conversion, wrongDuration, wrongSignal, wrongChannels }

@main private struct AudioConversionValidation {
    private static let frequency = 997.0

    static func main() throws {
        for destination in [44_100.0, 48_000.0] {
            try check(sourceRate: 24_000, destinationRate: destination, channels: 1,
                      interleaved: false, chunks: [6_000], name: "Realtime quarter-second chunks")
            try check(sourceRate: 24_000, destinationRate: destination, channels: 1,
                      interleaved: false, chunks: [1, 31, 479, 1_024, 4_097, 113, 6_000], name: "Irregular short chunks")
            try check(sourceRate: 24_000, destinationRate: destination, channels: 1,
                      interleaved: false, chunks: [120_000], name: "Complete WAV-sized response")
        }
        try check(sourceRate: 48_000, destinationRate: 24_000, channels: 2,
                  interleaved: false, chunks: [1_024, 480, 4_097], name: "Capture to Realtime")
        try check(sourceRate: 44_100, destinationRate: 16_000, channels: 2,
                  interleaved: true, chunks: [512, 4_097, 1_024], name: "Interleaved integer capture to ASR")
        print("PCM duration, pitch, channel agreement, chunk continuity, and final drain passed")
    }

    private static func check(sourceRate: Double, destinationRate: Double, channels: AVAudioChannelCount,
                              interleaved: Bool, chunks: [Int], name: String) throws {
        let source = AVAudioFormat(commonFormat: interleaved ? .pcmFormatInt16 : .pcmFormatFloat32,
                                   sampleRate: sourceRate, channels: channels, interleaved: interleaved)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: destinationRate,
                                   channels: 2, interleaved: false)!
        let converter = AVAudioConverter(from: source, to: target)!
        let sourceFrames = Int(sourceRate * 5)
        var rendered = [Float]()
        var offset = 0, chunkIndex = 0
        while offset < sourceFrames {
            let count = min(chunks[chunkIndex % chunks.count], sourceFrames - offset)
            chunkIndex += 1
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count))!
            input.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let sample = sin(2 * Double.pi * frequency * Double(offset + frame) / sourceRate) * 0.25
                for channel in 0..<Int(channels) {
                    if interleaved { input.int16ChannelData![0][frame * Int(channels) + channel] = Int16(sample * Double(Int16.max)) }
                    else { input.floatChannelData![channel][frame] = Float(sample) }
                }
            }
            guard let result = PCMBufferConverter.convert(input, using: converter,
                                                          endOfStream: chunks.count == 1 && chunks[0] == sourceFrames) else {
                throw CheckFailure.conversion
            }
            try append(result, to: &rendered)
            offset += count
        }
        guard let tail = PCMBufferConverter.convert(nil, using: converter, endOfStream: true) else {
            throw CheckFailure.conversion
        }
        try append(tail, to: &rendered)
        let expectedFrames = Int(destinationRate * 5)
        guard abs(rendered.count - expectedFrames) <= 1 else {
            print("FAIL \(name): \(rendered.count) frames, expected \(expectedFrames)")
            throw CheckFailure.wrongDuration
        }
        // Compare the continuous reference waveform away from the stream's two filter boundaries.
        var squaredError = 0.0
        let indices = 512..<(rendered.count - 512)
        for index in indices {
            let expected = sin(2 * Double.pi * frequency * Double(index) / destinationRate) * 0.25
            squaredError += pow(Double(rendered[index]) - expected, 2)
        }
        let rms = sqrt(squaredError / Double(indices.count))
        guard rms < 0.003 else { print("FAIL \(name): waveform RMS error \(rms)"); throw CheckFailure.wrongSignal }
        print("\(name): \(Int(sourceRate)) -> \(Int(destinationRate)), \(rendered.count) frames / \(Double(rendered.count) / destinationRate)s, RMS error \(rms)")
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to result: inout [Float]) throws {
        let count = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData else { throw CheckFailure.wrongChannels }
        for index in 0..<count {
            guard channels[0][index].isFinite, abs(channels[0][index] - channels[1][index]) < 0.0001 else {
                throw CheckFailure.wrongChannels
            }
        }
        result.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
    }
}
