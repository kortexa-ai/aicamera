import AVFoundation

/// Delivers exactly the frames AVAudioConverter requests. Keep the converter for a whole stream;
/// .noDataNow means another chunk can follow, and .endOfStream drains its final retained samples.
enum PCMBufferConverter {
    static func convert(
        _ input: AVAudioPCMBuffer?,
        using converter: AVAudioConverter,
        endOfStream: Bool = false
    ) -> AVAudioPCMBuffer? {
        let source = converter.inputFormat, target = converter.outputFormat
        guard input == nil || input?.format == source,
              input != nil || endOfStream,
              source.sampleRate > 0, target.sampleRate > 0 else { return nil }
        let frames = input?.frameLength ?? 0
        let ratio = target.sampleRate / source.sampleRate
        // Include room for the converter's retained filter state, including a final empty drain.
        let capacity = ceil(Double(frames) * ratio) + max(4_096, ceil(Double(converter.primeInfo.trailingFrames) * ratio))
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)),
              let scratch = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: max(1, min(frames, 4_096))) else { return nil }
        var offset: AVAudioFrameCount = 0
        var failed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, inputStatus in
            guard let input, offset < frames else {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            let count = min(requested, scratch.frameCapacity, frames - offset)
            guard count > 0 else { failed = true; inputStatus.pointee = .noDataNow; return nil }
            scratch.frameLength = count
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
            let stride = Int(source.streamDescription.pointee.mBytesPerFrame)
            guard stride > 0, sourceBuffers.count == destinationBuffers.count else {
                failed = true; inputStatus.pointee = .noDataNow; return nil
            }
            for channel in sourceBuffers.indices {
                guard let from = sourceBuffers[channel].mData, let to = destinationBuffers[channel].mData,
                      (Int(offset) + Int(count)) * stride <= Int(sourceBuffers[channel].mDataByteSize),
                      Int(count) * stride <= Int(destinationBuffers[channel].mDataByteSize) else {
                    failed = true; inputStatus.pointee = .noDataNow; return nil
                }
                to.copyMemory(from: from.advanced(by: Int(offset) * stride), byteCount: Int(count) * stride)
            }
            offset += count
            inputStatus.pointee = .haveData
            return scratch
        }
        guard !failed, error == nil, status != .error, offset == frames else { return nil }
        return output
    }
}
